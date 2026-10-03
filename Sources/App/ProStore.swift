// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import StoreKit

/// StoreKit 2 manager for AI Music Radar Pro.
///
/// Products (created in App Store Connect 2026-10-03, group "AI Music Radar Pro"):
/// - com.ragnus.pnge.pro.monthly  — $4.99/mo, 7-day trial
/// - com.ragnus.pnge.pro.yearly   — $29.99/yr, 7-day trial
/// - com.ragnus.pnge.lifetime     — $49.99 once, non-consumable
///
/// Entitlement = active Pro subscription OR owned Lifetime.
/// The entitlement is cached locally and refreshed on launch, on
/// Transaction.updates, and on restore.
///
/// Server loop: every verified purchase, restore and Transaction.updates item is
/// queued for `POST /api/iap/verify` (ServerSync / VerifyQueue, retried until the
/// server has it). StoreKit stays the source of truth for `isPro`; the server is
/// the cross-device record.
@MainActor
final class ProStore: ObservableObject {
    static let monthlyID = "com.ragnus.pnge.pro.monthly"
    static let yearlyID = "com.ragnus.pnge.pro.yearly"
    static let lifetimeID = "com.ragnus.pnge.lifetime"
    static let productIDs = [monthlyID, yearlyID, lifetimeID]

    /// Free tier: 3 saved takes, 30 s import/PDF, no MIDI/MusicXML.
    static let freeSaveLimit = 3
    static let freeImportSeconds = 30.0

    @Published private(set) var products: [Product] = []
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isLoadingProducts = false
    @Published var purchaseError: String?

    private var updatesTask: Task<Void, Never>?
    private var cache = EntitlementCache()

    init() {
        isPro = cache.isPro
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
    }

    // MARK: - Products

    func loadProducts() async {
        guard products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            // Yearly first, then monthly, then lifetime.
            let order = [Self.yearlyID, Self.monthlyID, Self.lifetimeID]
            products = loaded.sorted {
                (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99)
            }
        } catch {
            purchaseError = "Could not load prices: \(error.localizedDescription)"
        }
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    // MARK: - Purchase

    /// Purchase a product. Returns true if the user is now Pro.
    func purchase(_ product: Product) async -> Bool {
        purchaseError = nil
        Telemetry.shared.track(.purchaseStart, ["product": product.id])
        do {
            let result = try await product.purchase(options: [
                .appAccountToken(appAccountToken)
            ])
            switch result {
            case .success(let verification):
                let transaction = try checked(verification)
                ServerSync.report(transaction.id, transaction.appAccountToken, verification.jwsRepresentation)
                await transaction.finish()
                await refreshEntitlement()
                Telemetry.shared.track(.purchaseSuccess, ["product": product.id])
                return isPro
            case .userCancelled:
                Telemetry.shared.track(.purchaseFail, ["product": product.id, "reason": "cancelled"])
                return false
            case .pending:
                purchaseError = "Purchase is pending approval."
                Telemetry.shared.track(.purchaseFail, ["product": product.id, "reason": "pending"])
                return false
            @unknown default:
                Telemetry.shared.track(.purchaseFail, ["product": product.id, "reason": "unknown"])
                return false
            }
        } catch {
            purchaseError = "Purchase failed: \(error.localizedDescription)"
            // StoreKit error code only, never the message text.
            Telemetry.shared.track(.purchaseFail, ["product": product.id, "reason": "error",
                                                   "code": (error as NSError).code])
            return false
        }
    }

    /// Restore: sync with the App Store, then refresh from current entitlements.
    func restore() async -> Bool {
        purchaseError = nil
        do {
            try await AppStore.sync()
        } catch {
            purchaseError = "Restore failed: \(error.localizedDescription)"
            Telemetry.shared.track(.restore, ["result": "fail", "code": (error as NSError).code])
            return false
        }
        let restored = await reportCurrentEntitlements()
        await refreshEntitlement()
        Telemetry.shared.track(.restore, ["result": isPro ? "success" : "none", "restored": restored])
        if !isPro {
            purchaseError = "No Pro purchase found on this Apple ID."
        }
        return isPro
    }

    // MARK: - Entitlement

    /// Recompute Pro status from verified current entitlements.
    func refreshEntitlement() async {
        var pro = false
        for await result in Transaction.currentEntitlements {
            do {
                let transaction = try checked(result)
                if Self.productIDs.contains(transaction.productID) {
                    pro = true
                }
            } catch {
                continue
            }
        }
        isPro = pro
        cache.isPro = pro
        cache.lastRefresh = Date()
    }

    /// Queues the JWS of every verified current entitlement for the server. Returns the count.
    private func reportCurrentEntitlements() async -> Int {
        var count = 0
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checked(result), Self.productIDs.contains(transaction.productID) else { continue }
            ServerSync.report(transaction.id, transaction.appAccountToken, result.jwsRepresentation)
            count += 1
        }
        return count
    }

    private func listenForTransactions() async {
        for await result in Transaction.updates {
            do {
                let transaction = try checked(result)
                ServerSync.report(transaction.id, transaction.appAccountToken, result.jwsRepresentation)
                await transaction.finish()
                await refreshEntitlement()
            } catch {
                continue
            }
        }
    }

    private func checked<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw ProStoreError.unverifiedTransaction
        case .verified(let value):
            return value
        }
    }

    // MARK: - App account token

    /// Per-install token sent with every purchase so the server can link
    /// transactions to this install. Generated once, stored in UserDefaults.
    var appAccountToken: UUID { InstallIdentity.appAccountToken }
}

enum ProStoreError: Error {
    case unverifiedTransaction
}

// MARK: - Local entitlement cache

/// Persists the last known Pro status so the paywall gates work offline
/// and before the first StoreKit refresh completes.
private struct EntitlementCache {
    private let proKey = "pro.isPro"
    private let refreshKey = "pro.lastRefresh"

    var isPro: Bool {
        get { UserDefaults.standard.bool(forKey: proKey) }
        set { UserDefaults.standard.set(newValue, forKey: proKey) }
    }

    var lastRefresh: Date? {
        get { UserDefaults.standard.object(forKey: refreshKey) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: refreshKey) }
    }
}

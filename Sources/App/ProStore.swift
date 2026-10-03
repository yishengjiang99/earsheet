// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import StoreKit

/// StoreKit 2 purchases and the Pro entitlement.
///
/// Source of truth on the device: verified `Transaction.currentEntitlements` (works offline).
/// A small cache (UserDefaults) makes the launch state instant and covers brief StoreKit outages
/// until the cached expiry. Every verified transaction is also mirrored to the server
/// (`/iap/verify`, `/iap/restore`) keyed by the per-install `appAccountToken`; the server's
/// Apple-verified entitlement is a secondary signal (e.g. after a server-side notification).
@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()

    enum Plan: String, Codable {
        case monthly, yearly, lifetime
        init?(productID: String) {
            switch productID {
            case AppConfig.Product.monthly: self = .monthly
            case AppConfig.Product.yearly: self = .yearly
            case AppConfig.Product.lifetime: self = .lifetime
            default: return nil
            }
        }
        var title: String {
            switch self {
            case .monthly: "Pro Monthly"
            case .yearly: "Pro Yearly"
            case .lifetime: "Lifetime"
            }
        }
    }

    /// What the app last knew about the entitlement (persisted).
    struct CachedEntitlement: Codable, Equatable {
        var productID: String
        var expiresAt: Date?
        var isTrial: Bool
        var willAutoRenew: Bool?
        var updatedAt: Date

        /// Lifetime never expires; subscriptions are trusted until their expiry.
        func isActive(now: Date = Date()) -> Bool {
            guard Plan(productID: productID) != nil else { return false }
            if Plan(productID: productID) == .lifetime { return true }
            guard let exp = expiresAt else { return false }
            return exp > now
        }
    }

    enum LoadState: Equatable { case idle, loading, loaded, unavailable(String) }

    enum PurchaseOutcome: Equatable {
        case purchased(productID: String, isTrial: Bool, expiresAt: Date?)
        case cancelled
        case pending
        case failed(String)
    }

    enum RestoreOutcome: Equatable { case restored, nothingFound, failed(String) }

    @Published private(set) var products: [String: Product] = [:]
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var entitlement: CachedEntitlement?
    @Published private(set) var serverEntitlement: APIClient.Entitlement?
    @Published private(set) var trialEligible = true
    @Published private(set) var purchasingProductID: String?

    var isPro: Bool {
        if Self.forcePro { return true }
        if entitlement?.isActive() == true { return true }
        return serverEntitlement?.pro == true && serverEntitlementStillValid
    }

    var plan: Plan? { entitlement.flatMap { Plan(productID: $0.productID) } }

    private static let cacheKey = "ProEntitlementCache.v1"
    private var updatesTask: Task<Void, Never>?
    private let api: APIClient

    /// Debug/screenshots only: `MUSIC_RADAR_FORCE_PRO=1`.
    static var forcePro: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["MUSIC_RADAR_FORCE_PRO"] == "1"
        #else
        false
        #endif
    }

    init(api: APIClient = .shared, defaults: UserDefaults = .standard) {
        self.api = api
        if let data = defaults.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(CachedEntitlement.self, from: data) {
            entitlement = cached
        }
    }

    /// Call once at launch: listens for transactions made outside the paywall (renewals, Ask to
    /// Buy approvals, refunds, other devices), finishes leftovers, loads products, refreshes.
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task.detached(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(update: result, source: "updates")
            }
        }
        Task {
            for await result in Transaction.unfinished {
                await handle(update: result, source: "unfinished")
            }
            await loadProducts()
            await refreshEntitlements()
            await flushPendingVerifications()
            await refreshServerEntitlement()
        }
    }

    // MARK: - Products

    func loadProducts() async {
        guard loadState != .loading else { return }
        loadState = .loading
        do {
            let list = try await Product.products(for: AppConfig.Product.all)
            products = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
            loadState = list.isEmpty ? .unavailable("The App Store didn't return any plans.") : .loaded
            if let sub = (products[AppConfig.Product.yearly] ?? products[AppConfig.Product.monthly])?.subscription {
                trialEligible = await sub.isEligibleForIntroOffer
            }
        } catch {
            loadState = .unavailable(error.localizedDescription)
        }
    }

    func product(_ plan: Plan) -> Product? {
        switch plan {
        case .monthly: products[AppConfig.Product.monthly]
        case .yearly: products[AppConfig.Product.yearly]
        case .lifetime: products[AppConfig.Product.lifetime]
        }
    }

    /// Free-trial length offered on a product to this user (nil if not eligible / no offer).
    func trialDays(for product: Product) -> Int? {
        guard trialEligible, let offer = product.subscription?.introductoryOffer,
              offer.paymentMode == .freeTrial else { return nil }
        let p = offer.period
        switch p.unit {
        case .day: return p.value
        case .week: return p.value * 7
        case .month: return p.value * 30
        case .year: return p.value * 365
        @unknown default: return nil
        }
    }

    // MARK: - Purchase

    func purchase(_ product: Product, trigger: String) async -> PurchaseOutcome {
        purchasingProductID = product.id
        defer { purchasingProductID = nil }
        Telemetry.shared.track(.purchaseStart, ["product": product.id, "trigger": trigger])
        do {
            let token = InstallIdentity.appAccountToken
            let result = try await product.purchase(options: [.appAccountToken(token)])
            switch result {
            case .success(let verification):
                guard case .verified(let tx) = verification else {
                    Telemetry.shared.track(.purchaseFail, ["product": product.id, "error": "unverified"])
                    return .failed("The App Store couldn't verify this purchase.")
                }
                await apply(transaction: tx)
                // Queue for the server before finishing, so a dropped connection never loses it.
                mirrorToServer(jws: verification.jwsRepresentation)
                await tx.finish()
                let trial = Self.isIntroOffer(tx)
                Telemetry.shared.track(.purchaseSuccess, ["product": product.id, "trigger": trigger,
                                                          "is_trial": trial, "is_lifetime": tx.productType == .nonConsumable])
                if trial { Telemetry.shared.track(.trialStart, ["product": product.id]) }
                return .purchased(productID: tx.productID, isTrial: trial, expiresAt: tx.expirationDate)
            case .userCancelled:
                Telemetry.shared.track(.purchaseCancel, ["product": product.id, "trigger": trigger])
                return .cancelled
            case .pending:
                Telemetry.shared.track(.purchasePending, ["product": product.id, "trigger": trigger])
                return .pending
            @unknown default:
                return .failed("Unknown purchase result.")
            }
        } catch {
            Telemetry.shared.track(.purchaseFail, ["product": product.id, "trigger": trigger,
                                                   "error": Self.errorCode(error)])
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Restore

    func restore() async -> RestoreOutcome {
        Telemetry.shared.track(.restoreStart)
        do {
            try await AppStore.sync()
        } catch StoreKitError.userCancelled {
            Telemetry.shared.track(.restoreFail, ["error": "user_cancelled"])
            return .failed("Restore was cancelled.")
        } catch {
            Telemetry.shared.track(.restoreFail, ["error": Self.errorCode(error)])
            return .failed(error.localizedDescription)
        }
        let found = await refreshEntitlements(adoptToken: true)
        let jws = found.map(\.jws)
        if !jws.isEmpty {
            Task { [api] in
                if let r = try? await api.restore(signedTransactions: jws, appAccountToken: InstallIdentity.appAccountToken) {
                    await MainActor.run { self.serverEntitlement = r.entitlement }
                }
            }
        }
        let outcome: RestoreOutcome = isPro ? .restored : .nothingFound
        Telemetry.shared.track(.restoreSuccess, ["restored": found.count])
        return outcome
    }

    // MARK: - Entitlements

    /// Re-reads verified current entitlements and updates the cache.
    @discardableResult
    func refreshEntitlements(adoptToken: Bool = false) async -> [(tx: Transaction, jws: String)] {
        var found: [(tx: Transaction, jws: String)] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let tx) = result, tx.revocationDate == nil,
                  Plan(productID: tx.productID) != nil else { continue }
            found.append((tx, result.jwsRepresentation))
        }
        if adoptToken, let token = found.compactMap({ $0.tx.appAccountToken }).first {
            InstallIdentity.adopt(appAccountToken: token)
        }
        // Lifetime wins; otherwise the subscription with the latest expiry.
        let best = found.first { $0.tx.productType == .nonConsumable }
            ?? found.max { ($0.tx.expirationDate ?? .distantPast) < ($1.tx.expirationDate ?? .distantPast) }
        if let best {
            await apply(transaction: best.tx)
        } else {
            setEntitlement(nil)
        }
        return found
    }

    func refreshServerEntitlement() async {
        if let e = try? await api.entitlement(appAccountToken: InstallIdentity.appAccountToken) {
            serverEntitlement = e
        }
    }

    // MARK: - Private

    private nonisolated func handle(update result: VerificationResult<Transaction>, source: String) async {
        guard case .verified(let tx) = result else { return }
        await MainActor.run { self.mirrorToServer(jws: result.jwsRepresentation) }
        if tx.revocationDate != nil || (tx.expirationDate.map { $0 < Date() } ?? false) {
            await refreshEntitlements()
        } else {
            await apply(transaction: tx)
        }
        await tx.finish()
    }

    private func apply(transaction tx: Transaction) async {
        guard Plan(productID: tx.productID) != nil, tx.revocationDate == nil else { return }
        var renew: Bool?
        if let status = await tx.subscriptionStatus, case .verified(let info) = status.renewalInfo {
            renew = info.willAutoRenew
        }
        setEntitlement(CachedEntitlement(productID: tx.productID, expiresAt: tx.expirationDate,
                                         isTrial: Self.isIntroOffer(tx), willAutoRenew: renew, updatedAt: Date()))
    }

    private func setEntitlement(_ e: CachedEntitlement?) {
        entitlement = e
        if let e, let data = try? JSONEncoder().encode(e) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
    }

    // MARK: - Server mirror (retry queue)

    private static let pendingKey = "ProStore.pendingVerifyJWS.v1"
    private var flushingPending = false

    /// JWS not yet accepted by `/api/iap/verify` (persisted; retried on launch and foreground).
    var pendingVerifications: [String] {
        UserDefaults.standard.stringArray(forKey: Self.pendingKey) ?? []
    }

    private func mirrorToServer(jws: String) {
        var list = pendingVerifications
        if !list.contains(jws) { list.append(jws) }
        UserDefaults.standard.set(Array(list.suffix(20)), forKey: Self.pendingKey)
        Task { await flushPendingVerifications() }
    }

    /// Sends queued transactions to the server. A 4xx (e.g. a sandbox JWS the server rejects)
    /// is dropped; offline / 5xx keeps it for the next try.
    func flushPendingVerifications() async {
        guard !flushingPending else { return }
        flushingPending = true
        defer { flushingPending = false }
        let token = InstallIdentity.appAccountToken
        for jws in pendingVerifications {
            var done = false
            do {
                let r = try await api.verify(signedTransaction: jws, appAccountToken: token)
                if let e = r.entitlement { serverEntitlement = e }
                done = true
            } catch let e as APIClient.APIError {
                if let c = e.statusCode, (400..<500).contains(c), c != 429 { done = true }
            } catch {}
            if done {
                UserDefaults.standard.set(pendingVerifications.filter { $0 != jws }, forKey: Self.pendingKey)
            } else {
                break
            }
        }
    }

    /// StoreKit error code only (no localized message text) for telemetry.
    static func errorCode(_ error: Error) -> String {
        if let e = error as? StoreKitError {
            switch e {
            case .userCancelled: return "user_cancelled"
            case .networkError: return "network"
            case .systemError: return "system"
            case .notAvailableInStorefront: return "not_available_in_storefront"
            case .notEntitled: return "not_entitled"
            case .unknown: return "unknown"
            default: return "storekit_other"
            }
        }
        if let e = error as? Product.PurchaseError {
            switch e {
            case .invalidQuantity: return "invalid_quantity"
            case .productUnavailable: return "product_unavailable"
            case .purchaseNotAllowed: return "purchase_not_allowed"
            case .ineligibleForOffer: return "ineligible_for_offer"
            case .invalidOfferIdentifier, .invalidOfferPrice, .invalidOfferSignature, .missingOfferParameters:
                return "invalid_offer"
            @unknown default: return "purchase_other"
            }
        }
        let ns = error as NSError
        return "\(ns.domain.prefix(40)):\(ns.code)"
    }

    private var serverEntitlementStillValid: Bool {
        guard let e = serverEntitlement else { return false }
        guard let s = e.expiresAt else { return e.plan == "lifetime" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let d = f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        return (d ?? .distantPast) > Date()
    }

    static func isIntroOffer(_ tx: Transaction) -> Bool {
        if #available(iOS 17.2, *) {
            return tx.offer?.type == .introductory
        }
        return tx.offerType == .introductory
    }
}

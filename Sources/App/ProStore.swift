// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import StoreKit

/// StoreKit 2 manager for AI Music Radar Pro.
///
/// Products (created in App Store Connect 2026-10-03, group "AI Music Radar Pro"):
/// - com.ragnus.pnge.pro.monthly  — $4.99/mo (USA), 1-week free trial, level 2
/// - com.ragnus.pnge.pro.yearly   — $29.99/yr (USA), 1-week free trial, level 1
/// - com.ragnus.pnge.lifetime     — $49.99 once (USA), non-consumable
/// Family Sharing is off for all three (matches ASC and Products.storekit). The app never hardcodes
/// these prices: the paywall reads Product.price / displayPrice / priceFormatStyle.
///
/// Entitlement = active Pro subscription OR owned Lifetime.
/// The entitlement is cached locally and refreshed on launch, on every return to the foreground
/// (ContentView), on Transaction.updates, on restore, and at the earliest known expiry date (StoreKit
/// emits no update when a subscription lapses).
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
    /// Shown on the paywall (with a Try Again button) when prices could not be loaded or came back empty.
    @Published private(set) var productsError: String?
    /// Product.SubscriptionInfo.isEligibleForIntroOffer per subscription product id.
    @Published private(set) var introEligibility: [String: Bool] = [:]
    @Published var purchaseError: String?
    /// A purchase is awaiting the App Store (the buy sheet is up or the transaction is being verified).
    @Published private(set) var purchaseInFlight = false
    /// Ask to Buy: the purchase waits for approval; cleared once Pro turns on.
    @Published private(set) var purchasePendingApproval = false
    /// A purchase failed (not a cancel) since launch: no automatic upgrade prompts for the rest of the session.
    @Published private(set) var purchaseFailedThisSession = false

    /// True while upgrade prompts must stay quiet because of a purchase (in flight, pending or failed).
    var purchaseActive: Bool { purchaseInFlight || purchasePendingApproval || purchaseFailedThisSession }

    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var cache = EntitlementCache()
    private let sync: () async throws -> Void

    /// `sync` is `AppStore.sync()` in production; tests inject a closure that throws.
    init(sync: @escaping () async throws -> Void = { try await AppStore.sync() }) {
        self.sync = sync
        isPro = cache.isPro
        updatesTask = Task { [weak self] in
            await self?.listenForTransactions()
        }
    }

    deinit {
        updatesTask?.cancel()
        expiryTask?.cancel()
    }

    // MARK: - Products

    /// Loads the three products. `force` reloads even when products are already loaded (Try Again).
    func loadProducts(force: Bool = false) async {
        guard force || products.isEmpty, !isLoadingProducts else { return }
        isLoadingProducts = true
        productsError = nil
        defer { isLoadingProducts = false }
        do {
            let loaded = try await Product.products(for: Self.productIDs)
            products = Self.sortedForPaywall(loaded)
            var eligibility: [String: Bool] = [:]
            for product in products {
                if let sub = product.subscription {
                    eligibility[product.id] = await sub.isEligibleForIntroOffer
                }
            }
            introEligibility = eligibility
            if products.isEmpty {
                productsError = "Prices aren't available right now. Check your connection and try again."
            }
        } catch {
            productsError = StoreMessages.loadPricesFailure(error)
        }
    }

    /// Yearly first, then monthly, then lifetime; unknown ids last.
    static func sortedForPaywall(_ loaded: [Product]) -> [Product] {
        loaded.sorted { paywallRank($0.id) < paywallRank($1.id) }
    }

    static func paywallRank(_ id: String) -> Int {
        [yearlyID, monthlyID, lifetimeID].firstIndex(of: id) ?? 99
    }

    /// The free trial this account can get for `product`, or nil (not eligible, no intro offer, or not a free trial).
    func eligibleTrial(for product: Product) -> PaywallPricing.Trial? {
        let offer = product.subscription?.introductoryOffer
        return PaywallPricing.eligibleTrial(
            isEligible: introEligibility[product.id] ?? false,
            offerIsFreeTrial: offer?.paymentMode == .freeTrial,
            offerPeriod: offer.map { PaywallPricing.Period($0.period) }
        )
    }

    func product(for id: String) -> Product? {
        products.first { $0.id == id }
    }

    // MARK: - Purchase

    /// Purchase a product. Returns true if the user is now Pro.
    func purchase(_ product: Product) async -> Bool {
        purchaseError = nil
        purchaseInFlight = true
        defer { purchaseInFlight = false }
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
                PurchaseFunnel.cancelled.record(productID: product.id)
                return false
            case .pending:
                purchaseError = "Purchase is pending approval."
                purchasePendingApproval = true
                PurchaseFunnel.pending.record(productID: product.id)
                return false
            @unknown default:
                PurchaseFunnel.unknown.record(productID: product.id)
                return false
            }
        } catch {
            if StoreMessages.isUserCancel(error) {
                PurchaseFunnel.cancelled.record(productID: product.id)
                return false
            }
            purchaseError = StoreMessages.purchaseFailure(error)
            purchaseFailedThisSession = true
            Telemetry.shared.track(.purchaseFail, StoreMessages.failureProperties(error, productID: product.id))
            return false
        }
    }

    /// Restore: sync with the App Store, then refresh from current entitlements.
    /// A user cancel of the App Store sign-in prompt is silent (`.cancelled`, no alert).
    /// The result carries the message; callers present it (Settings and the paywall each show their own alert).
    @discardableResult
    func restore() async -> RestoreResult {
        purchaseError = nil
        do {
            try await sync()
        } catch {
            if StoreMessages.isUserCancel(error) {
                Telemetry.shared.track(.restore, ["result": "cancelled"])
                return .cancelled
            }
            let message = StoreMessages.restoreFailure(error)
            Telemetry.shared.track(.restore, ["result": "fail", "code": (error as NSError).code])
            return .failed(message)
        }
        let restored = await reportCurrentEntitlements()
        await refreshEntitlement()
        Telemetry.shared.track(.restore, ["result": isPro ? "success" : "none", "restored": restored])
        return isPro ? .restored : .none
    }

    // MARK: - Entitlement

    /// Recompute Pro status from verified current entitlements.
    func refreshEntitlement() async {
        var pro = false
        var earliestExpiry: Date?
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checked(result), Self.productIDs.contains(transaction.productID) else { continue }
            pro = true
            if let expiry = transaction.expirationDate {
                earliestExpiry = earliestExpiry.map { min($0, expiry) } ?? expiry
            }
        }
        isPro = pro
        if pro { purchasePendingApproval = false }
        cache.isPro = pro
        cache.lastRefresh = Date()
        scheduleExpiryRefresh(at: pro ? earliestExpiry : nil)
    }

    /// Seconds to wait before re-checking entitlements for a subscription that expires at `expiry`.
    /// A little after the expiry so StoreKit has dropped it; never a tight loop for an expiry that is
    /// already past but still listed (billing grace period): that rechecks every minute.
    nonisolated static func refreshDelay(forExpiry expiry: Date, now: Date = Date()) -> TimeInterval {
        let remaining = expiry.timeIntervalSince(now)
        return remaining > 0 ? remaining + 2 : 60
    }

    /// StoreKit posts no Transaction update when a subscription lapses, so wake up at the expiry date.
    private func scheduleExpiryRefresh(at expiry: Date?) {
        expiryTask?.cancel()
        expiryTask = nil
        guard let expiry else { return }
        let delay = Self.refreshDelay(forExpiry: expiry)
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(min(delay, 7 * 86400) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshEntitlement()
        }
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

/// Non-success purchase outcomes for the anonymous funnel. Cancel and Ask-to-Buy pending are not
/// failures: `purchase_fail` is kept for real errors (see `StoreMessages.failureProperties`).
enum PurchaseFunnel {
    case cancelled, pending, unknown

    func telemetry(productID: String) -> (event: Telemetry.Event, properties: [String: Any]) {
        switch self {
        case .cancelled: return (.purchaseCancel, ["product": productID])
        case .pending: return (.purchasePending, ["product": productID])
        case .unknown: return (.purchaseFail, ["product": productID, "reason": "unknown"])
        }
    }

    func record(productID: String) {
        let t = telemetry(productID: productID)
        Telemetry.shared.track(t.event, t.properties)
    }
}

/// Outcome of `ProStore.restore()`.
enum RestoreResult: Equatable {
    /// Pro is active after the sync (found a purchase, or Pro was already active).
    case restored
    /// The sync worked but this Apple ID has no Pro purchase.
    case none
    /// The user dismissed the App Store sign-in prompt: show nothing.
    case cancelled
    /// Plain-language, retryable message.
    case failed(String)

    static let noneMessage = "No Pro purchase found on this Apple ID."
    static let restoredMessage = "Pro is active on this Apple ID. Thanks for supporting AI Music Radar!"

    /// Text for the result alert (shared by Settings and the paywall); nil when nothing should be shown.
    var message: String? {
        switch self {
        case .restored: return Self.restoredMessage
        case .none: return Self.noneMessage
        case .cancelled: return nil
        case .failed(let message): return message
        }
    }
}

enum ProStoreError: Error, LocalizedError {
    case unverifiedTransaction

    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction: return StoreMessages.unverified
        }
    }
}

/// Plain-language copy for StoreKit failures. Raw `Error` text (e.g. "The operation couldn't be
/// completed (EarSheet.ProStoreError error 0)") is never shown to the user or sent to analytics.
enum StoreMessages {
    static let unverified = "We couldn't verify this purchase with the App Store. If you were charged, tap Restore Purchases."
    static let network = "Couldn't reach the App Store. Check your connection and try again."
    static let purchaseGeneric = "Purchase didn't go through. Try again."
    static let purchaseNotAllowed = "Purchases are turned off on this device (Screen Time or parental controls)."
    static let restoreGeneric = "Couldn't restore purchases. Try again in a moment."
    static let pricesNetwork = "Couldn't load prices. Check your connection and try again."

    static func isUserCancel(_ error: Error) -> Bool {
        if let sk = error as? StoreKitError, case .userCancelled = sk { return true }
        return false
    }

    static func isNetwork(_ error: Error) -> Bool {
        if let sk = error as? StoreKitError, case .networkError = sk { return true }
        return error is URLError
    }

    static func purchaseFailure(_ error: Error) -> String {
        if let e = error as? ProStoreError, e == .unverifiedTransaction { return unverified }
        if isNetwork(error) { return network }
        if let e = error as? Product.PurchaseError, case .purchaseNotAllowed = e { return purchaseNotAllowed }
        return purchaseGeneric
    }

    static func restoreFailure(_ error: Error) -> String {
        isNetwork(error) ? network : restoreGeneric
    }

    static func loadPricesFailure(_ error: Error) -> String {
        isNetwork(error) ? pricesNetwork : "Prices aren't available right now. Try again in a moment."
    }

    /// Analytics properties for a real purchase failure: a fixed reason plus the numeric error code, never message text.
    static func failureProperties(_ error: Error, productID: String) -> [String: Any] {
        if let e = error as? ProStoreError, e == .unverifiedTransaction {
            return ["product": productID, "reason": "unverified"]
        }
        if isNetwork(error) { return ["product": productID, "reason": "network"] }
        return ["product": productID, "reason": "error", "code": (error as NSError).code]
    }
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

// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKit
import StoreKitTest
@testable import EarSheet

/// Entitlement refresh: a lapsed subscription must stop being Pro without a relaunch (#9).
@MainActor
final class EntitlementManagerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "pro.isPro")
        UserDefaults.standard.removeObject(forKey: "pro.lastRefresh")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "pro.isPro")
        UserDefaults.standard.removeObject(forKey: "pro.lastRefresh")
        super.tearDown()
    }

    func testRefreshDelayWaitsForExpiryAndNeverSpins() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ProStore.refreshDelay(forExpiry: now.addingTimeInterval(300), now: now), 302, accuracy: 0.001)
        XCTAssertEqual(ProStore.refreshDelay(forExpiry: now.addingTimeInterval(-5), now: now), 60,
                       "an expiry that is already past (billing grace) rechecks every minute, not in a tight loop")
    }

    func testExpiredSubscriptionBlocksAfterRefresh() async throws {
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: PaywallPricingTests.storekitURL)
        } catch {
            throw XCTSkip("SKTestSession unavailable here: \(error)")
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        let store = ProStore()
        await store.loadProducts(force: true)
        guard let monthly = store.product(for: ProStore.monthlyID) else {
            throw XCTSkip("local StoreKit returned no products (\(store.productsError ?? "-"))")
        }
        let becamePro = try await store.purchaseOrSkip(monthly)
        XCTAssertTrue(becamePro)
        XCTAssertTrue(store.isPro)

        try session.expireSubscription(productIdentifier: ProStore.monthlyID)
        await store.refreshEntitlement()
        XCTAssertFalse(store.isPro, "an expired subscription must lock Pro on the next refresh")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "pro.isPro"), "the offline cache must follow")
    }
}

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
        UserDefaults.standard.removeObject(forKey: "pro.isPro")
        defer { UserDefaults.standard.removeObject(forKey: "pro.isPro") }
        let entitlements = FakeEntitlements()
        let store = ProStore(entitlementSource: entitlements.source)

        entitlements.records = [EntitlementRecord(productID: ProStore.monthlyID,
                                                  expirationDate: Date().addingTimeInterval(3600))]
        await store.refreshEntitlement()
        XCTAssertTrue(store.isPro)

        entitlements.records = [] // StoreKit drops the subscription once it lapses
        await store.refreshEntitlement()
        XCTAssertFalse(store.isPro, "an expired subscription must lock Pro on the next refresh")
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "pro.isPro"), "the offline cache must follow")
    }
}

/// Mutable stand-in for `Transaction.currentEntitlements` (see issue #86: no headless StoreKit purchases).
@MainActor
final class FakeEntitlements {
    var records: [EntitlementRecord] = []
    var source: EntitlementSource { { [unowned self] in self.records } }
}

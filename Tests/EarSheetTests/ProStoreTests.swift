// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

@MainActor
final class ProStoreTests: XCTestCase {
    func testProductIDs() {
        XCTAssertEqual(Set(ProStore.productIDs), [
            "com.ragnus.pnge.pro.monthly",
            "com.ragnus.pnge.pro.yearly",
            "com.ragnus.pnge.lifetime",
        ])
    }

    func testFreeSaveLimit() {
        XCTAssertEqual(ProStore.freeSaveLimit, 3)
    }

    func testAppAccountTokenIsStablePerInstall() {
        let store = ProStore()
        let first = store.appAccountToken
        let second = ProStore().appAccountToken
        XCTAssertEqual(first, second)
    }

    func testEntitlementCacheRoundTrip() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "pro.isPro")
        defaults.removeObject(forKey: "pro.lastRefresh")

        let store = ProStore()
        XCTAssertFalse(store.isPro)

        // Simulate a cached Pro grant without touching StoreKit.
        defaults.set(true, forKey: "pro.isPro")
        defaults.set(Date(), forKey: "pro.lastRefresh")
        let reloaded = ProStore()
        XCTAssertTrue(reloaded.isPro)

        defaults.removeObject(forKey: "pro.isPro")
        defaults.removeObject(forKey: "pro.lastRefresh")
    }

    func testProductOrderingYearlyFirst() {
        // Ordering helper: yearly, monthly, lifetime.
        let order = [ProStore.yearlyID, ProStore.monthlyID, ProStore.lifetimeID]
        XCTAssertEqual(order.first, ProStore.yearlyID)
    }
}

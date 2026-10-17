// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKit
import StoreKitTest
@testable import EarSheet

/// Restore Purchases outcomes (#16, #15).
@MainActor
final class RestoreFlowTests: XCTestCase {
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

    func testSyncCancelledIsSilent() async {
        let store = ProStore(sync: { throw StoreKitError.userCancelled })
        let result = await store.restore()
        XCTAssertEqual(result, .cancelled)
        XCTAssertNil(store.purchaseError, "cancelling the App Store sign-in must not raise an alert")
        XCTAssertFalse(store.isPro)
    }

    func testSyncNetworkFailureIsFriendlyAndRetryable() async {
        let store = ProStore(sync: { throw StoreKitError.networkError(URLError(.notConnectedToInternet)) })
        let result = await store.restore()
        XCTAssertEqual(result, .failed(StoreMessages.network))
        XCTAssertEqual(store.purchaseError, StoreMessages.network)
    }

    func testSyncUnknownFailureHasNoRawText() async {
        struct Raw: LocalizedError { var errorDescription: String? { "RAWSYSTEMTEXT" } }
        let store = ProStore(sync: { throw Raw() })
        let result = await store.restore()
        XCTAssertEqual(result, .failed(StoreMessages.restoreGeneric))
        XCTAssertEqual(store.purchaseError, StoreMessages.restoreGeneric)
    }
}

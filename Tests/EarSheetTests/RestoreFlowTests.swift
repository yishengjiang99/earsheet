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
        XCTAssertNil(store.purchaseError, "the result carries the message; no stale paywall alert is left behind")
    }

    func testSyncUnknownFailureHasNoRawText() async {
        struct Raw: LocalizedError { var errorDescription: String? { "RAWSYSTEMTEXT" } }
        let store = ProStore(sync: { throw Raw() })
        let result = await store.restore()
        XCTAssertEqual(result, .failed(StoreMessages.restoreGeneric))
        XCTAssertEqual(result.message, StoreMessages.restoreGeneric)
        XCTAssertNil(store.purchaseError)
    }

    func testResultMessages() {
        XCTAssertNil(RestoreResult.cancelled.message)
        XCTAssertEqual(RestoreResult.none.message, RestoreResult.noneMessage)
        XCTAssertEqual(RestoreResult.restored.message, RestoreResult.restoredMessage)
        XCTAssertEqual(RestoreResult.failed("x").message, "x")
    }

    func testRestoreResults() async throws {
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: PaywallPricingTests.storekitURL)
        } catch {
            throw XCTSkip("SKTestSession unavailable here: \(error)")
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true

        let store = ProStore(sync: {})
        await store.loadProducts(force: true)
        XCTAssertNotNil(store.product(for: ProStore.monthlyID), "local StoreKit returned no products (\(store.productsError ?? "-"))")
        let none = await store.restore()
        XCTAssertEqual(none, .none, "a clean account has nothing to restore")
        XCTAssertFalse(store.isPro)

        try session.buyProduct(productIdentifier: ProStore.monthlyID) // Product.purchase() hangs headless (#86)
        await store.refreshEntitlement()
        XCTAssertTrue(store.isPro)
        let active = await store.restore()
        XCTAssertEqual(active, .restored, "restore on an active Pro account reports success")
    }
}

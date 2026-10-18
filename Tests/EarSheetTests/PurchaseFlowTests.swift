// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import StoreKit
import StoreKitTest
@testable import EarSheet

/// Purchase failure copy and analytics reasons: plain language, no raw `Error` text (#28).
final class PurchaseFlowTests: XCTestCase {
    private struct Raw: Error, LocalizedError {
        var errorDescription: String? { "RAWSYSTEMTEXT (domain error 7)" }
    }

    private var sampleErrors: [Error] {
        [
            ProStoreError.unverifiedTransaction,
            StoreKitError.networkError(URLError(.notConnectedToInternet)),
            StoreKitError.unknown,
            StoreKitError.notAvailableInStorefront,
            Product.PurchaseError.productUnavailable,
            Product.PurchaseError.purchaseNotAllowed,
            URLError(.timedOut),
            Raw(),
            NSError(domain: "SomeDomain", code: 5, userInfo: [NSLocalizedDescriptionKey: "RAWSYSTEMTEXT"]),
        ]
    }

    func testPurchaseErrorCopyHasNoRawErrorText() {
        for error in sampleErrors {
            for text in [StoreMessages.purchaseFailure(error), StoreMessages.restoreFailure(error),
                         StoreMessages.loadPricesFailure(error)] {
                XCTAssertFalse(text.contains("RAWSYSTEMTEXT"), "\(error) -> \(text)")
                XCTAssertFalse(text.contains("ProStoreError"), "\(error) -> \(text)")
                XCTAssertFalse(text.contains("couldn’t be completed"), "\(error) -> \(text)")
                XCTAssertFalse(text.contains("error 0"), "\(error) -> \(text)")
                XCTAssertFalse(text.isEmpty)
            }
        }
    }

    func testUnverifiedExplainsAndPointsToRestore() {
        let text = StoreMessages.purchaseFailure(ProStoreError.unverifiedTransaction)
        XCTAssertTrue(text.contains("verify"))
        XCTAssertTrue(text.contains("Restore Purchases"))
        XCTAssertEqual(ProStoreError.unverifiedTransaction.localizedDescription, StoreMessages.unverified)
    }

    func testNetworkAndGenericMapping() {
        XCTAssertEqual(StoreMessages.purchaseFailure(StoreKitError.networkError(URLError(.notConnectedToInternet))),
                       StoreMessages.network)
        XCTAssertEqual(StoreMessages.purchaseFailure(Product.PurchaseError.productUnavailable),
                       StoreMessages.purchaseGeneric)
        XCTAssertEqual(StoreMessages.purchaseFailure(Raw()), StoreMessages.purchaseGeneric)
        XCTAssertEqual(StoreMessages.restoreFailure(Raw()), StoreMessages.restoreGeneric)
        XCTAssertEqual(StoreMessages.restoreFailure(StoreKitError.networkError(URLError(.timedOut))),
                       StoreMessages.network)
    }

    func testUserCancelIsDetected() {
        XCTAssertTrue(StoreMessages.isUserCancel(StoreKitError.userCancelled))
        XCTAssertFalse(StoreMessages.isUserCancel(StoreKitError.unknown))
        XCTAssertFalse(StoreMessages.isUserCancel(Raw()))
    }

    func testFailureAnalyticsUsesReasonAndCodeNeverText() {
        let unverified = StoreMessages.failureProperties(ProStoreError.unverifiedTransaction, productID: "p")
        XCTAssertEqual(unverified["reason"] as? String, "unverified")
        XCTAssertNil(unverified["code"])
        let net = StoreMessages.failureProperties(StoreKitError.networkError(URLError(.timedOut)), productID: "p")
        XCTAssertEqual(net["reason"] as? String, "network")
        let other = StoreMessages.failureProperties(NSError(domain: "X", code: 42), productID: "p")
        XCTAssertEqual(other["reason"] as? String, "error")
        XCTAssertEqual(other["code"] as? Int, 42)
        for props in [unverified, net, other] {
            XCTAssertFalse(props.values.contains { ($0 as? String)?.contains("RAWSYSTEMTEXT") == true })
        }
    }

    func testPaywallDismissesWhenProTurnsOn() {
        XCTAssertTrue(PaywallView.shouldDismiss(wasPro: false, isPro: true))
        XCTAssertFalse(PaywallView.shouldDismiss(wasPro: true, isPro: true))
        XCTAssertFalse(PaywallView.shouldDismiss(wasPro: true, isPro: false))
        XCTAssertFalse(PaywallView.shouldDismiss(wasPro: false, isPro: false))
    }

    @MainActor
    func testApprovalOfPendingPurchaseSetsPro() async throws {
        UserDefaults.standard.removeObject(forKey: "pro.isPro")
        defer { UserDefaults.standard.removeObject(forKey: "pro.isPro") }
        let entitlements = FakeEntitlements()
        let store = ProStore(entitlementSource: entitlements.source)

        await store.refreshEntitlement()
        XCTAssertFalse(store.isPro, "a purchase waiting for Ask to Buy approval is not Pro")

        // Approval: the entitlement appears and the next refresh (Transaction.updates) flips Pro on.
        entitlements.records = [EntitlementRecord(productID: ProStore.yearlyID,
                                                  expirationDate: Date().addingTimeInterval(86400 * 365))]
        await store.refreshEntitlement()
        XCTAssertTrue(store.isPro, "approval must turn Pro on without another purchase call")
        XCTAssertFalse(store.purchasePendingApproval)
    }
}

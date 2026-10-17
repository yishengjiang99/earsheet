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
        let session: SKTestSession
        do {
            session = try SKTestSession(contentsOf: PaywallPricingTests.storekitURL)
        } catch {
            throw XCTSkip("SKTestSession unavailable here: \(error)")
        }
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = true

        let store = ProStore()
        await store.loadProducts(force: true)
        guard let yearly = store.product(for: ProStore.yearlyID) else {
            throw XCTSkip("local StoreKit returned no products (\(store.productsError ?? "-"))")
        }
        let becamePro = await store.purchase(yearly)
        XCTAssertFalse(becamePro, "Ask to Buy returns pending, not Pro")
        XCTAssertFalse(store.isPro)
        XCTAssertEqual(store.purchaseError, "Purchase is pending approval.")

        let pending = try XCTUnwrap(session.allTransactions().first { $0.productIdentifier == ProStore.yearlyID })
        try session.approveAskToBuyTransaction(identifier: pending.identifier)

        // Transaction.updates -> refreshEntitlement flips isPro (the paywall observes it and closes).
        for _ in 0..<50 where !store.isPro {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(store.isPro, "approval must turn Pro on without another purchase call")
    }
}

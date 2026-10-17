// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Anonymous analytics: allow-listed scalar properties only; funnel events are distinguishable (#29).
final class TelemetryPrivacyTests: XCTestCase {
    func testCancelAndPendingAreNotFailures() {
        let cancel = PurchaseFunnel.cancelled.telemetry(productID: ProStore.yearlyID)
        XCTAssertEqual(cancel.event, .purchaseCancel)
        XCTAssertEqual(cancel.event.rawValue, "purchase_cancel")
        let pending = PurchaseFunnel.pending.telemetry(productID: ProStore.yearlyID)
        XCTAssertEqual(pending.event, .purchasePending)
        XCTAssertEqual(pending.event.rawValue, "purchase_pending")
        XCTAssertNotEqual(cancel.event, .purchaseFail)
        XCTAssertNotEqual(pending.event, .purchaseFail)
        // purchase_fail stays for real errors.
        XCTAssertEqual(PurchaseFunnel.unknown.telemetry(productID: "p").event, .purchaseFail)
        XCTAssertEqual(Telemetry.Event.paywallDismiss.rawValue, "paywall_dismiss")
        for name in Telemetry.Event.allCases.map(\.rawValue) {
            XCTAssertNotNil(name.range(of: "^[a-z][a-z0-9_]{1,63}$", options: .regularExpression), name)
        }
    }

    func testTriggerPropertyAllowedAndPIIKeysStillDropped() {
        let out = Telemetry.sanitize([
            "trigger": "settings",
            "product": ProStore.monthlyID,
            "email": "a@b.example",
            "title": "My song",
            "name": "Yisheng",
            "file_name": "demo.wav",
            "appAccountToken": UUID().uuidString,
        ])
        XCTAssertEqual(out?["trigger"], TelemetryValue.string("settings"))
        XCTAssertEqual(out?["product"], TelemetryValue.string(ProStore.monthlyID))
        XCTAssertEqual(Set((out ?? [:]).keys), Set(["trigger", "product"]))
        XCTAssertTrue(Telemetry.allowedPropertyKeys.contains("trigger"))
    }
}

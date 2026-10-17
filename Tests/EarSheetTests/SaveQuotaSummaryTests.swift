// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// "2 of 3 free pieces" Library meter (P1.10): text, visibility and the gate behind the link.
extension UpgradePromptPolicyTests {
    func testMeterTextAndVisibility() {
        XCTAssertFalse(SaveQuotaSummary(isPro: false, count: 0).isVisible, "nothing to count yet")
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 1).text, "1 of 3 free pieces")
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 2).text, "2 of 3 free pieces")
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 3).text, "3 of 3 free pieces")
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 5).text, "3 of 3 free pieces", "never above the limit")
        for count in 0...6 {
            XCTAssertFalse(SaveQuotaSummary(isPro: true, count: count).isVisible, "hidden for Pro (\(count))")
        }
        XCTAssertTrue(SaveQuotaSummary(isPro: false, count: 1).isVisible)
    }

    func testMeterNoteOnTheLastFreeSlotAndWhenFull() {
        XCTAssertNil(SaveQuotaSummary(isPro: false, count: 1).note)
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 2).note, "One free slot left.")
        XCTAssertNil(SaveQuotaSummary(isPro: false, count: 2).actionTitle, "not a link before the limit")
        let full = SaveQuotaSummary(isPro: false, count: 3)
        XCTAssertTrue(full.isFull)
        XCTAssertEqual(full.actionTitle, "Keep unlimited")
        XCTAssertNotNil(full.note)
        XCTAssertEqual(SaveQuotaSummary(isPro: false, count: 1, limit: 1).text, "1 of 1 free pieces")
        XCTAssertTrue(full.accessibilityLabel.hasPrefix("3 of 3 free pieces"))
    }

    func testMeterLinkGoesThroughThePolicyAsAnUncountedTap() {
        let suite = "SaveQuotaSummaryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let t = PaywallTriggers(defaults: defaults, report: { _, _ in })
        let free = UpgradePromptContext(isPro: false, finishedTakes: 3)
        for _ in 0..<7 { XCTAssertTrue(t.decision(.meter, userInitiated: true, context: free).isShow) }
        XCTAssertEqual(t.history, UpgradePromptHistory(), "meter taps do not touch the caps")
        XCTAssertEqual(t.decision(.meter, context: UpgradePromptContext(isPro: true, finishedTakes: 3)),
                       .suppress(.pro))
        XCTAssertFalse(PaywallTriggers.Trigger.meter.isAutomatic)
        XCTAssertEqual(PaywallTriggers.Trigger.meter.analyticsName, "meter")
    }
}

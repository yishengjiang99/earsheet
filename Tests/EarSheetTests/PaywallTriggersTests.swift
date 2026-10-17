// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Automatic paywall caps (PAYWALL_FLOW §2) with injected defaults.
@MainActor
final class PaywallTriggersTests: XCTestCase {
    private func makeTriggers() -> PaywallTriggers {
        let suite = "PaywallTriggersTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PaywallTriggers(defaults: defaults)
    }

    func testUserInitiatedDismissDoesNotCount() {
        let triggers = makeTriggers()
        XCTAssertTrue(triggers.canShowAuto(.saveLimit))

        // Far more than the 5-dismissal lifetime cap: all user-initiated (Keep it, banner button).
        for _ in 0..<10 { triggers.recordPaywallDismissed(.userInitiated) }

        XCTAssertTrue(triggers.canShowAuto(.saveLimit), "no cooldown and no lifetime cutoff from user taps")
    }

    func testAutomaticDismissStartsCooldown() {
        let triggers = makeTriggers()
        triggers.recordAutoShown(.saveLimit)
        triggers.recordPaywallDismissed(.automatic)
        triggers.resetSession()
        XCTAssertFalse(triggers.canShowAuto(.saveLimit), "72 h cooldown after an automatic dismissal")
    }

    func testFiveAutomaticDismissalsStopAutomaticPrompts() {
        let suite = "PaywallTriggersTests.cap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "paywall.dismissCount")
        let triggers = PaywallTriggers(defaults: defaults)
        XCTAssertFalse(triggers.canShowAuto(.saveLimit))
    }
}

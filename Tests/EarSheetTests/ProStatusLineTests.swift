// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Pro status detail in Settings and the quiet Library "Go Pro" entry (P9.4).
extension SettingsTests {
    private var statusUTC: TimeZone { TimeZone(identifier: "UTC")! }
    private var statusLocale: Locale { Locale(identifier: "en_US") }
    private func statusDate(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testStatusLineForEveryKindOfEntitlement() {
        let renewing = ProStatus(plan: .yearly, expiresAt: statusDate("2026-11-17T12:00:00Z"), isTrial: false, willRenew: true)
        XCTAssertEqual(renewing.statusLine(locale: statusLocale, timeZone: statusUTC), "Pro Yearly · renews Nov 17")

        var ending = renewing
        ending.willRenew = false
        XCTAssertEqual(ending.statusLine(locale: statusLocale, timeZone: statusUTC), "Pro Yearly · expires Nov 17")

        var unknown = renewing
        unknown.willRenew = nil
        XCTAssertEqual(unknown.statusLine(locale: statusLocale, timeZone: statusUTC), "Pro Yearly · active until Nov 17")

        let trial = ProStatus(plan: .monthly, expiresAt: statusDate("2026-10-24T12:00:00Z"), isTrial: true, willRenew: true)
        XCTAssertEqual(trial.statusLine(locale: statusLocale, timeZone: statusUTC), "Pro Monthly (trial) · ends Oct 24")

        XCTAssertEqual(ProStatus(plan: .lifetime, expiresAt: nil, isTrial: false, willRenew: nil).statusLine(), "Lifetime Pro")
        XCTAssertEqual(ProStatus(plan: .monthly, expiresAt: nil, isTrial: false, willRenew: nil).statusLine(), "Pro Monthly")
    }

    func testDateFollowsTheUsersTimeZone() {
        let instant = statusDate("2026-11-17T02:00:00Z")
        let la = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(ProStatus.formatDate(instant, locale: statusLocale, timeZone: statusUTC), "Nov 17")
        XCTAssertEqual(ProStatus.formatDate(instant, locale: statusLocale, timeZone: la), "Nov 16")
    }

    func testSettingsRowSubtitleShowsPlanForProAndThePitchForFree() {
        let status = ProStatus(plan: .yearly, expiresAt: statusDate("2026-11-17T12:00:00Z"), isTrial: false, willRenew: true)
        let pro = SettingsView.goProSubtitle(isPro: true, status: status, locale: statusLocale, timeZone: statusUTC)
        XCTAssertTrue(pro.hasPrefix("Pro Yearly · renews Nov 17"))
        XCTAssertTrue(pro.contains("manage your subscription"))
        XCTAssertTrue(SettingsView.goProSubtitle(isPro: true, status: nil).hasPrefix("You have Pro"))
        XCTAssertEqual(SettingsView.goProSubtitle(isPro: false, status: nil), "Unlimited saves, MIDI, MusicXML & full PDF")
        XCTAssertEqual(SettingsView.goProSubtitle(isPro: false, status: status), "Unlimited saves, MIDI, MusicXML & full PDF",
                       "a stale status never leaks into a free user's row")
    }

    func testToolbarGoProIsHiddenForPro() {
        XCTAssertTrue(LibraryGoProEntry.isVisible(isPro: false))
        XCTAssertFalse(LibraryGoProEntry.isVisible(isPro: true))
    }

    @MainActor
    func testToolbarAndSettingsTapsAreUncountedAndNeverForPro() {
        let suite = "ProStatusLineTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let t = PaywallTriggers(defaults: defaults, report: { _, _ in })
        let free = UpgradePromptContext(isPro: false, finishedTakes: 1)
        let pro = UpgradePromptContext(isPro: true, finishedTakes: 1)
        for trigger in [PaywallTriggers.Trigger.toolbar, .settings] {
            XCTAssertFalse(trigger.isAutomatic)
            for _ in 0..<6 { XCTAssertTrue(t.decision(trigger, userInitiated: true, context: free).isShow) }
            XCTAssertEqual(t.decision(trigger, userInitiated: true, context: pro), .suppress(.pro))
        }
        XCTAssertEqual(t.history, UpgradePromptHistory(), "user-initiated entries never count toward the caps")
        XCTAssertEqual(PaywallTriggers.Trigger.toolbar.analyticsName, "toolbar")
    }
}

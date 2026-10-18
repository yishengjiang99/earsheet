// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Soft export interstitial (P2.1): first share vs locked-row taps under the shared policy.
extension UpgradePromptPolicyTests {
    private func interstitialTriggers() -> PaywallTriggers {
        let suite = "ExportInterstitialTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return PaywallTriggers(defaults: defaults, report: { _, _ in })
    }

    func testFirstShareShowsOnceForARealTake() {
        let t = interstitialTriggers()
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: true, isPro: false, purchaseActive: false, triggers: t),
                     "a sample is not the user's finished take")
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: true, purchaseActive: false, triggers: t))
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: true, triggers: t))
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: false, triggers: nil))
        XCTAssertEqual(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: false, triggers: t),
                       .firstShare)
        t.resetSession()
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: false, triggers: t),
                     "only the first share, ever")
    }

    func testFirstShareHonorsTheSessionCapLikeAnyAutomaticPrompt() {
        let t = interstitialTriggers()
        t.recordAutoShown(.saveLimit)
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: false, triggers: t))
    }

    func testLockedRowTapsAlwaysOpenAndNeverCount() {
        let t = interstitialTriggers()
        let before = t.history
        for _ in 0..<8 {
            let entry = ExportInterstitialFlow.entryForLockedRow(.midi, isPro: false, purchaseActive: false, triggers: t)
            XCTAssertEqual(entry, .lockedRow(.midi))
            ExportInterstitialFlow.closed(entry!, tookPlans: false, isPro: false, triggers: t)
        }
        XCTAssertEqual(ExportInterstitialFlow.entryForLockedRow(.musicXML, isPro: false, purchaseActive: true, triggers: t),
                       .lockedRow(.musicXML), "a tap opens even while a purchase is active")
        XCTAssertEqual(t.history, before, "paywall.dismissCount, caps and session are untouched by locked-row taps")
        XCTAssertEqual(t.history.lifetimeDismissals, 0)
    }

    func testLockedRowStillOpensAfterAutomaticPromptsAreExhaustedButNotForPro() {
        let suite = "ExportInterstitialTests.cap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(5, forKey: "paywall.dismissCount")
        let t = PaywallTriggers(defaults: defaults, report: { _, _ in })
        XCTAssertEqual(ExportInterstitialFlow.entryForLockedRow(.midi, isPro: false, purchaseActive: false, triggers: t),
                       .lockedRow(.midi))
        XCTAssertNil(ExportInterstitialFlow.entryForLockedRow(.midi, isPro: true, purchaseActive: false, triggers: t))
        XCTAssertNil(ExportInterstitialFlow.entryOnOpen(isSample: false, isPro: false, purchaseActive: false, triggers: t))
    }

    func testOnlyAnUntakenAutomaticInterstitialCountsAsADismissal() {
        let t = interstitialTriggers()
        ExportInterstitialFlow.closed(.firstShare, tookPlans: true, isPro: false, triggers: t)
        XCTAssertEqual(t.history.lifetimeDismissals, 0, "went on to the plans")
        ExportInterstitialFlow.closed(.firstShare, tookPlans: false, isPro: true, triggers: t)
        XCTAssertEqual(t.history.lifetimeDismissals, 0, "became Pro")
        ExportInterstitialFlow.closed(.lockedRow(.midi), tookPlans: false, isPro: false, triggers: t)
        XCTAssertEqual(t.history.lifetimeDismissals, 0, "a tap-opened sheet never counts")
        ExportInterstitialFlow.closed(.firstShare, tookPlans: false, isPro: false, triggers: t)
        XCTAssertEqual(t.history.lifetimeDismissals, 1)
    }

    func testInterstitialCopyOffersFreePDFAndOnlyClaimsARealTrial() {
        XCTAssertEqual(ExportInterstitialFlow.freePDFTitle, "Share free PDF (first 30 s)")
        XCTAssertEqual(ExportInterstitialFlow.primaryTitle(trialText: "7 days"), "Try Pro free for 7 days")
        XCTAssertEqual(ExportInterstitialFlow.primaryTitle(trialText: nil), "See Pro plans")
        XCTAssertFalse(ExportInterstitialFlow.body(title: "Take 3", trialText: nil).contains("free"))
        XCTAssertTrue(ExportInterstitialFlow.body(title: "Take 3", trialText: "7 days").contains("first 7 days are free"))
        XCTAssertTrue(ExportInterstitialFlow.body(title: "Take 3", trialText: nil).contains("Take 3"))
        XCTAssertEqual(ExportInterstitialFlow.Entry.lockedRow(.midi).trigger, .exportLockedRow)
        XCTAssertEqual(ExportInterstitialFlow.Entry.firstShare.trigger, .firstExport)
    }
}

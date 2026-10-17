// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// After a purchase (P3.5): the confirmation line and resuming the export the user tapped.
extension PurchaseFlowTests {
    private var utc: TimeZone { TimeZone(identifier: "UTC")! }
    private var us: Locale { Locale(identifier: "en_US") }
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testPurchaseFromAMIDIRowResumesTheMIDIExportExactlyOnce() {
        var resume = ExportResume()
        XCTAssertNil(resume.proChanged(wasPro: false, isPro: true), "nothing pending: nothing to resume")
        resume.request(.midi)
        XCTAssertNil(resume.proChanged(wasPro: true, isPro: true), "no flip, no resume")
        XCTAssertNil(resume.proChanged(wasPro: true, isPro: false), "losing Pro never resumes")
        XCTAssertEqual(resume.proChanged(wasPro: false, isPro: true), .midi, "Pro turned on: run the MIDI export")
        XCTAssertNil(resume.proChanged(wasPro: false, isPro: true), "only once")
        XCTAssertNil(resume.pending)
    }

    func testMusicXMLRowResumesMusicXMLAndLatestRequestWins() {
        var resume = ExportResume()
        resume.request(.midi)
        resume.request(.musicXML)
        XCTAssertEqual(resume.proChanged(wasPro: false, isPro: true), .musicXML)
    }

    func testClosingThePaywallWithoutBuyingForgetsTheExport() {
        var resume = ExportResume()
        resume.request(.midi)
        resume.cancel()
        XCTAssertNil(resume.proChanged(wasPro: false, isPro: true), "a later restore must not fire a stale export")
    }

    func testConfirmationForATrialNamesTheEndDate() {
        let status = ProStatus(plan: .yearly, expiresAt: date("2026-10-24T12:00:00Z"), isTrial: true, willRenew: nil)
        XCTAssertEqual(status.confirmation(locale: us, timeZone: utc), "Pro is on. Trial ends Oct 24.")
    }

    func testConfirmationForPaidLifetimeAndUnknown() {
        let paid = ProStatus(plan: .monthly, expiresAt: date("2026-11-17T12:00:00Z"), isTrial: false, willRenew: true)
        XCTAssertEqual(paid.confirmation(locale: us, timeZone: utc), "Pro is on. Renews Nov 17.")
        var cancelled = paid
        cancelled.willRenew = false
        XCTAssertEqual(cancelled.confirmation(locale: us, timeZone: utc), "Pro is on until Nov 17.")
        XCTAssertEqual(ProStatus(plan: .lifetime, expiresAt: nil, isTrial: false, willRenew: nil).confirmation(),
                       "Pro is on. Lifetime, thank you.")
        XCTAssertEqual(ProStatus(plan: .yearly, expiresAt: nil, isTrial: false, willRenew: nil).confirmation(),
                       "Pro is on.")
    }

    func testBestEntitlementPrefersLifetimeThenLatestEnd() {
        let early = ProStatus(plan: .monthly, expiresAt: date("2026-11-01T00:00:00Z"), isTrial: false, willRenew: nil)
        let late = ProStatus(plan: .yearly, expiresAt: date("2027-10-01T00:00:00Z"), isTrial: false, willRenew: nil)
        let life = ProStatus(plan: .lifetime, expiresAt: nil, isTrial: false, willRenew: nil)
        XCTAssertEqual(ProStatus.best([early, late]), late)
        XCTAssertEqual(ProStatus.best([early, life, late]), life)
        XCTAssertNil(ProStatus.best([]))
    }

    @MainActor
    func testProductIDsMapToPlans() {
        XCTAssertEqual(ProStatus.plan(forProductID: ProStore.monthlyID), .monthly)
        XCTAssertEqual(ProStatus.plan(forProductID: ProStore.yearlyID), .yearly)
        XCTAssertEqual(ProStatus.plan(forProductID: ProStore.lifetimeID), .lifetime)
        XCTAssertNil(ProStatus.plan(forProductID: "other"))
    }
}

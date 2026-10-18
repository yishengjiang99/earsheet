// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Import-limit sheet (P1.11): when a free import is offered the choice, and the gate the import task waits on.
extension UpgradePromptPolicyTests {
    func testLongFreeImportPromptsAndOthersGoStraightThrough() {
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 45, isPro: false), .prompt)
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 30.5, isPro: false), .prompt)
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 30, isPro: false), .proceed, "exactly 30 s fits")
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 12, isPro: false), .proceed)
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 45, isPro: true), .proceed, "never for Pro")
        XCTAssertEqual(ImportLimitPrompt.decision(durationSeconds: 60, isPro: true), .proceed)
    }

    func testImportLimitCopyDerivesFromTheRealLimits() {
        XCTAssertEqual(ImportLimitPrompt.clock(48), "0:48")
        XCTAssertEqual(ImportLimitPrompt.clock(59.6), "1:00")
        XCTAssertEqual(ImportLimitPrompt.title(durationSeconds: 48), "This file is 0:48 long")
        XCTAssertTrue(ImportLimitPrompt.body.contains("\(Int(ImportPolicy.freeSeconds)) s"))
        XCTAssertTrue(ImportLimitPrompt.body.contains("\(Int(ImportPolicy.proSeconds)) s"))
        XCTAssertEqual(ImportLimitPrompt.freeButtonTitle, "Write the first 30 s free")
    }

    func testImportLimitIsAnAutomaticCappedTrigger() {
        let ctx = UpgradePromptContext(isPro: false, finishedTakes: 2)
        let now = Date()
        XCTAssertEqual(UpgradePromptPolicy.decide(.importLimit, context: ctx, history: UpgradePromptHistory(), now: now), .show)
        XCTAssertEqual(UpgradePromptPolicy.decide(.importLimit, context: UpgradePromptContext(isPro: false, finishedTakes: 0),
                                                  history: UpgradePromptHistory(), now: now),
                       .suppress(.noValueYet), "first import before any take: no sheet, free import continues")
    }

    func testGateReturnsTheChoice() async {
        let gate = ImportLimitGate()
        let task = Task { await gate.ask(durationSeconds: 48) }
        while gate.request == nil { await Task.yield() }
        XCTAssertEqual(gate.request?.durationSeconds, 48)
        gate.resolve(.writeFirstFree)
        let choice = await task.value
        XCTAssertEqual(choice, .writeFirstFree)
        XCTAssertNil(gate.request)
        gate.resolve(.cancel)
    }

    func testGateCancelledWhenTheImportTaskIsCancelled() async {
        let gate = ImportLimitGate()
        let task = Task { await gate.ask(durationSeconds: 40) }
        while gate.request == nil { await Task.yield() }
        task.cancel()
        let choice = await task.value
        XCTAssertEqual(choice, .cancel)
        XCTAssertNil(gate.request)
    }

    func testNewAskSupersedesThePendingOne() async {
        let gate = ImportLimitGate()
        let first = Task { await gate.ask(durationSeconds: 40) }
        while gate.request == nil { await Task.yield() }
        let firstID = gate.request?.id
        let second = Task { await gate.ask(durationSeconds: 50) }
        let firstChoice = await first.value
        XCTAssertEqual(firstChoice, .cancel)
        while gate.request == nil || gate.request?.id == firstID { await Task.yield() }
        XCTAssertEqual(gate.request?.durationSeconds, 50)
        gate.resolve(.pro)
        let secondChoice = await second.value
        XCTAssertEqual(secondChoice, .pro)
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

final class ExportFlowTests: XCTestCase {
    @MainActor
    func testSecondExportIgnoredWhilePreparing() async {
        let c = ExportCoordinator()
        var runs = 0
        var release: CheckedContinuation<Void, Never>?

        XCTAssertFalse(c.isPreparing)
        let first = c.runExclusively {
            runs += 1
            await withCheckedContinuation { release = $0 }
        }
        XCTAssertTrue(first)
        XCTAssertTrue(c.isPreparing)

        let second = c.runExclusively { runs += 1 }
        XCTAssertFalse(second)
        XCTAssertTrue(c.isPreparing)

        var spins = 0
        while release == nil, spins < 1000 { await Task.yield(); spins += 1 }
        XCTAssertNotNil(release)
        release?.resume()
        spins = 0
        while c.isPreparing, spins < 1000 { await Task.yield(); spins += 1 }

        XCTAssertFalse(c.isPreparing)
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(c.runExclusively { runs += 1 })
    }

    func testBaseNameKeepsUnicodeAndFallsBack() {
        XCTAssertEqual(ExportFileName.base(for: "夜曲"), "夜曲")
        XCTAssertEqual(ExportFileName.base(for: "Étude n°1 – Ça va"), "Étude n1  Ça va")
        XCTAssertEqual(ExportFileName.base(for: "My Song_2-final"), "My Song_2-final")
        XCTAssertEqual(ExportFileName.base(for: "a/b\\c:d*e?f\"g<h>i|j"), "abcdefghij")
        XCTAssertEqual(ExportFileName.base(for: ""), ExportFileName.fallback)
        XCTAssertEqual(ExportFileName.base(for: "   "), ExportFileName.fallback)
        XCTAssertEqual(ExportFileName.base(for: "???///"), ExportFileName.fallback)
        XCTAssertEqual(ExportFileName.base(for: "..\u{0007}"), ExportFileName.fallback)
        XCTAssertEqual(ExportFileName.base(for: String(repeating: "夜", count: 200)).count, ExportFileName.maxLength)
    }
}

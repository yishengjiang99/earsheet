// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

/// Library persistence and file hygiene (temp copies, WAV files, takes.json).
@MainActor
final class LibraryStorageTests: XCTestCase {
    // MARK: - Import temp copies (F9.8)

    func testImportRemovesTemporaryCopy() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0, 1, 2]).write(to: tmp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path))
        XCTAssertTrue(ImportCleanup.isTemporary(tmp))
        ImportCleanup.removeTemporaryCopy(at: tmp)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
        // Already gone: a second call is harmless (error and cancel paths may both clean up).
        ImportCleanup.removeTemporaryCopy(at: tmp)
    }

    func testImportCleanupLeavesFilesOutsideTemporaryDirectory() throws {
        let caches = try XCTUnwrap(FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        let file = caches.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data([0]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertFalse(ImportCleanup.isTemporary(file))
        ImportCleanup.removeTemporaryCopy(at: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}

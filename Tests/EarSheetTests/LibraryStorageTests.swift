// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
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

    // MARK: - Persistence errors (F7.1)

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeTake(_ title: String) -> Take {
        let events = [NoteEvent(onset: 0, offset: 0.5, midi: 60, velocity: 80)]
        return Take(id: UUID(), title: title, createdAt: Date(), score: Quantizer.quantize(events),
                    isSample: false, events: events)
    }

    private func corruptBackups(in dir: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("takes.corrupt-") }
    }

    func testCorruptFileIsPreservedAndNotOverwritten() throws {
        let dir = try makeTempDirectory()
        let garbage = Data("this is not json".utf8)
        try garbage.write(to: dir.appendingPathComponent("takes.json"))

        let library = TakeLibrary(directory: dir)
        XCTAssertTrue(library.userTakes.isEmpty)
        XCTAssertNotNil(library.notice, "the user is told")
        let backups = try corruptBackups(in: dir)
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(backups.first)), garbage, "original bytes preserved")

        // The next save writes a fresh file but never touches the preserved backup.
        _ = library.addTake(title: "New", score: makeTake("x").score, events: makeTake("x").events)
        XCTAssertEqual(try corruptBackups(in: dir).count, 1)
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(try corruptBackups(in: dir).first)), garbage)
        let saved = try JSONDecoder().decode([Take].self, from: Data(contentsOf: dir.appendingPathComponent("takes.json")))
        XCTAssertEqual(saved.map(\.title), ["New"])
    }

    func testPartiallyInvalidArrayKeepsValidTakes() throws {
        let dir = try makeTempDirectory()
        let good = [makeTake("Take A"), makeTake("Take B")]
        let encoded = try JSONEncoder().encode(good)
        var objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [Any])
        objects.insert(["bogus": 1], at: 1)
        let mixed = try JSONSerialization.data(withJSONObject: objects)
        try mixed.write(to: dir.appendingPathComponent("takes.json"))

        let library = TakeLibrary(directory: dir)
        XCTAssertEqual(library.userTakes.map(\.title), ["Take A", "Take B"], "valid takes survive one bad element")
        XCTAssertNotNil(library.notice)
        XCTAssertEqual(try corruptBackups(in: dir).count, 1, "the original is kept as a backup")
        XCTAssertEqual(TakeLibrary.decodeTakes(mixed)?.skipped, 1)
        XCTAssertNil(TakeLibrary.decodeTakes(Data("{}".utf8)), "not an array at all")
    }

    func testWriteFailurePostsNotice() throws {
        let dir = try makeTempDirectory()
        // A regular file where the library folder should be: every write under it fails.
        let blocker = dir.appendingPathComponent("not-a-folder")
        try Data([0]).write(to: blocker)
        let library = TakeLibrary(directory: blocker)
        XCTAssertNil(library.notice)
        _ = library.addTake(title: "Doomed", score: makeTake("x").score, events: nil)
        let notice = try XCTUnwrap(library.notice, "a failed write is reported, not swallowed")
        XCTAssertTrue(notice.hasPrefix("Could not save your takes"))
    }

    func testHealthyFileLoadsWithoutNotice() throws {
        let dir = try makeTempDirectory()
        let encoded = try JSONEncoder().encode([makeTake("Only")])
        try encoded.write(to: dir.appendingPathComponent("takes.json"))
        let library = TakeLibrary(directory: dir)
        XCTAssertEqual(library.userTakes.map(\.title), ["Only"])
        XCTAssertNil(library.notice)
        XCTAssertTrue(try corruptBackups(in: dir).isEmpty)
    }
}

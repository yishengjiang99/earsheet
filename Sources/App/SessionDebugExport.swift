// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet

/// Debug export for a record session: the mic PCM as a 16-bit WAV plus the
/// transcribed note array as pretty-printed JSON (pastable into chat).
enum SessionDebugExport {
    static func fileTag() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    static func writeWAV(samples: [Float], tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(tag)-audio.wav")
        try WavWriter.data(samples: samples,
                           sampleRate: Int(AudioRecorder.targetSampleRate))
            .write(to: url, options: .atomic)
        return url
    }

    /// Pretty-printed JSON array of {midi, onset, offset, velocity}, sorted by onset.
    static func notesJSONString(notes: [NoteEvent]) -> String {
        let sorted = notes.sorted { $0.onset < $1.onset }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(sorted) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    static func writeNotesJSON(notes: [NoteEvent], tag: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-\(tag)-notes.json")
        try Data(notesJSONString(notes: notes).utf8).write(to: url, options: .atomic)
        return url
    }
}

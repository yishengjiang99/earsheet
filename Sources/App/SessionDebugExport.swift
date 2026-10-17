// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet

/// Files for a record session: the take's mic audio as a 16-bit WAV (kept with the take) and the
/// transcribed notes as pretty-printed JSON (shared from the Export screen).
enum SessionDebugExport {
    /// Pretty-printed JSON array of {midi, onset, offset, velocity}, sorted by onset.
    static func notesJSONString(notes: [NoteEvent]) -> String {
        let sorted = notes.sorted { $0.onset < $1.onset }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(sorted) else { return "[]" }
        return String(data: d, encoding: .utf8) ?? "[]"
    }

    /// Persists session PCM as a WAV in the library's Application Support dir so the
    /// take's Export screen can share it later. Returns the filename, or nil on failure.
    static func persistSessionAudio(_ samples: [Float]) -> String? {
        let name = UUID().uuidString + ".wav"
        let wav = WavWriter.data(samples: samples, sampleRate: Int(AudioRecorder.targetSampleRate))
        do {
            try wav.write(to: TakeLibrary.audioURL(fileName: name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }
}

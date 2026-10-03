// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet
import HearSheet
import Foundation

/// Simulator acceptance for the library-first redesign's new paths:
/// - StreamingTranscriber (live listening) matches batch Transcriber,
///   including the final partial window that short takes live in.
/// - Take JSON round-trips through Codable (persistence contract).
/// - MP3Encoder emits non-empty, frame-synced MP3 bytes.
/// The Core ML package comes from OMR_MODELS_DIR (ios-sim.yml sets
/// TEST_RUNNER_OMR_MODELS_DIR; xcodebuild strips the prefix for the simulator).
final class StreamingExportTests: XCTestCase {
    // MARK: - Model loading (mirrors ImportTranscriptionTests)

    private func modelsDirectory() -> URL? {
        // xcodebuild strips TEST_RUNNER_ and forwards the rest to the simulator.
        if let dir = ProcessInfo.processInfo.environment["OMR_MODELS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            if FileManager.default.fileExists(
                atPath: url.appendingPathComponent("BasicPitchPoly.mlpackage").path) {
                return url
            }
        }
        return nil
    }

    private func loadModel() throws -> BasicPitchModel {
        let dir = try XCTUnwrap(modelsDirectory(),
                                "model directory missing: run scripts/fetch-models")
        do {
            return try BasicPitchModel(modelsDirectory: dir)
        } catch {
            throw XCTSkip("could not load BasicPitchPoly.mlpackage: \(error)")
        }
    }

    /// Drive a StreamingTranscriber the way ListeningView does: small
    /// appended chunks with pump() after each, then finish() + finalize().
    private func streamTranscribe(_ samples: [Float], model: BasicPitchModel) throws -> [NoteEvent] {
        let streamer = StreamingTranscriber(model: model)
        var i = 0
        while i < samples.count {
            let j = min(samples.count, i + 4096)
            streamer.append(Array(samples[i..<j]))
            try streamer.pump()
            i = j
        }
        try streamer.finish()
        return streamer.finalize()
    }

    private func triadSamples() throws -> [Float] {
        guard let wavURL = Bundle(for: Self.self).url(forResource: "triad", withExtension: "wav") else {
            throw XCTSkip("triad.wav not in test bundle")
        }
        return try AudioImport.loadMono22050(url: wavURL)
    }

    // MARK: - Streaming/batch equivalence

    func testStreamingMatchesBatchOnTriadWav() throws {
        let samples = try triadSamples()
        let model = try loadModel()
        let batch = try Transcriber.transcribe(samples: samples, model: model)
        XCTAssertFalse(batch.isEmpty, "batch should hear the C major triad")
        let streamed = try streamTranscribe(samples, model: model)
        XCTAssertEqual(streamed, batch, "live streaming must match batch transcription")
    }

    func testShortTakeMatchesBatch() throws {
        // Half a second of audio: with the 3840-sample front pad the whole
        // take fits inside one window, so every frame lives in the final
        // partial window the old pump()-only drain dropped.
        let samples = Array(try triadSamples().prefix(11025))
        let model = try loadModel()
        let batch = try Transcriber.transcribe(samples: samples, model: model)
        let streamed = try streamTranscribe(samples, model: model)
        XCTAssertEqual(streamed, batch, "short take: streaming must match batch")
        if !batch.isEmpty {
            XCTAssertFalse(streamed.isEmpty, "streaming dropped the take's only window")
        }
    }

    // MARK: - Take persistence

    func testTakeCodableRoundTrip() throws {
        let score = QuantizedScore(
            notes: [QuantizedNote(midi: 60, velocity: 80, start16: 0, duration16: 4)],
            tempoBPM: 120,
            meter: .fourFour,
            key: MusicalKey(tonic: 0, isMinor: false),
            secondsPer16th: 0.125)
        let take = Take(id: UUID(),
                        title: "Round Trip",
                        createdAt: Date(timeIntervalSince1970: 1_000_000),
                        score: score,
                        isSample: false)
        let data = try JSONEncoder().encode(take)
        let back = try JSONDecoder().decode(Take.self, from: data)
        XCTAssertEqual(back, take)
    }

    // MARK: - MP3 export

    func testMP3EncodeEmitsFrameSyncedBytes() throws {
        // 1 s stereo 440 Hz sine at 44100 Hz.
        let sampleRate = 44100
        var pcm = [Float](repeating: 0, count: sampleRate * 2)
        for i in 0..<sampleRate {
            let s = Float(sin(2 * .pi * 440 * Double(i) / Double(sampleRate)) * 0.5)
            pcm[2 * i] = s
            pcm[2 * i + 1] = s
        }
        let mp3 = try MP3Encoder.encode(interleaved: pcm, sampleRate: sampleRate, channels: 2)
        XCTAssertGreaterThan(mp3.count, 1000, "MP3 output suspiciously small")

        // MP3 frame sync: 11 set bits (0xFFE). LAME emits no ID3v2 by itself
        // (the app would have to prepend lame_get_id3v2_tag), so the first
        // frame header is at offset 0.
        let bytes = [UInt8](mp3)
        XCTAssertEqual(bytes[0], 0xFF)
        XCTAssertEqual(bytes[1] & 0xE0, 0xE0, "missing MP3 frame sync")

        // A second of 128 kbps CBR is ~38 frames; demand several syncs so a
        // lone header can't pass.
        var syncs = 0
        for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF && (bytes[i + 1] & 0xE0) == 0xE0 {
            syncs += 1
        }
        XCTAssertGreaterThanOrEqual(syncs, 10, "expected many MP3 frames, found \(syncs)")
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet

/// Where an import came from (telemetry `source` is "import" for audio, "video" for video).
enum ImportSource: String, Equatable {
    case audio, video, midi

    var noun: String {
        switch self {
        case .audio: "file"
        case .video: "video"
        case .midi: "MIDI file"
        }
    }
}

/// Specific, actionable text for an import failure (too long, no audio track, unreadable).
enum ImportErrorMessage {
    static func message(for error: Error, source: ImportSource) -> String {
        let limit = Int(Transcriber.maxDurationSeconds)
        let tooLong = "That \(source.noun) is longer than \(limit) seconds. Trim it and try again."
        if let e = error as? AudioImport.ImportError {
            switch e {
            case .durationLimitExceeded: return tooLong
            case .noAudioTrack: return "That video has no audio."
            case .conversionFailed: return generic(source)
            }
        }
        if let e = error as? Transcriber.TranscribeError {
            switch e {
            case .durationLimitExceeded: return tooLong
            case .emptyAudio: return emptyAudio(source)
            case .tooQuiet: return "That \(source.noun) is too quiet to transcribe."
            }
        }
        return generic(source)
    }

    static func generic(_ source: ImportSource) -> String {
        switch source {
        case .audio: "Could not read that audio file."
        case .video: "Could not read that video's audio."
        case .midi: "Could not read that MIDI file."
        }
    }

    static func emptyAudio(_ source: ImportSource) -> String {
        source == .video ? "No audio found in that video." : "No audio found in that file."
    }
}

/// UI state of the audio/video import task: drives the "Transcribing…" overlay and disables the
/// import entry points while busy. Each import gets a token so a cancelled task that finishes late
/// cannot clear the state of a newer import.
struct ImportCoordinator: Equatable {
    enum State: Equatable {
        case idle
        case importing(ImportSource)
    }

    private(set) var state: State = .idle
    private var token: UUID?

    var isImporting: Bool { state != .idle }

    /// Starts an import; nil when one is already running (the caller must not start another).
    mutating func begin(_ source: ImportSource) -> UUID? {
        guard !isImporting else { return nil }
        let id = UUID()
        token = id
        state = .importing(source)
        return id
    }

    /// Ends the import started with `id`; ignored if that import was already cancelled/replaced.
    mutating func finish(_ id: UUID) {
        guard token == id else { return }
        cancel()
    }

    /// Ends whatever is running (user pressed Cancel).
    mutating func cancel() {
        token = nil
        state = .idle
    }

    /// Notice for a file that decoded to no audio at all.
    static func emptyAudioNotice(for source: ImportSource) -> String {
        ImportErrorMessage.emptyAudio(source)
    }
}

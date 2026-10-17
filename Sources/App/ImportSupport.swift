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

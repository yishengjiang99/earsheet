// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet

/// Audio/video import length policy. Free imports transcribe the first 30 s of a file; Pro
/// imports up to 60 s (the engine cap). Files longer than 60 s are rejected for everyone
/// (`AudioImport` throws before decoding). The paywall copy is derived from these numbers.
@MainActor
enum ImportPolicy {
    static let freeSeconds = ProStore.freeImportSeconds
    static let proSeconds = Transcriber.maxDurationSeconds

    static func maxSeconds(isPro: Bool) -> Double { isPro ? proSeconds : freeSeconds }

    /// Samples transcribed from an import at the 22050 Hz model rate.
    static func maxSamples(isPro: Bool) -> Int {
        Int(maxSeconds(isPro: isPro) * AudioRecorder.targetSampleRate)
    }

    /// Keeps only the first `maxSamples(isPro:)` samples; `wasTrimmed` is true when audio was dropped.
    static func trim(_ samples: [Float], isPro: Bool) -> (samples: [Float], wasTrimmed: Bool) {
        let limit = maxSamples(isPro: isPro)
        guard samples.count > limit else { return (samples, false) }
        return (Array(samples.prefix(limit)), true)
    }

    /// Message shown after a free import was shortened (nil for Pro or untrimmed imports).
    static func trimmedNotice(isPro: Bool, wasTrimmed: Bool) -> String? {
        guard wasTrimmed, !isPro else { return nil }
        return "Free imports use the first \(seconds(freeSeconds)) of a file, so that is what was transcribed. "
            + "Pro imports up to \(seconds(proSeconds))."
    }

    // MARK: - Paywall copy (single source so it cannot drift from the real limits)

    static var paywallHeader: String {
        "Unlimited saves, imports up to \(seconds(proSeconds)), and MIDI, MusicXML & full PDF export."
    }
    static var benefitText: String { "Audio & video imports up to \(seconds(proSeconds))" }
    static var comparisonFree: String { "First \(seconds(freeSeconds))" }
    static var comparisonPro: String { "Up to \(seconds(proSeconds))" }

    private static func seconds(_ s: Double) -> String { "\(Int(s)) s" }
}

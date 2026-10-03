// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet
import SF2Player

/// Renders a score to downloadable audio/photo files.
///
/// Audio goes through the same SF2Player package (shared SF2Engine synth) as live playback
/// (`SF2OfflineRenderer`), so the MP3 sounds exactly like the in-app play
/// button. Sheet photos are rendered from the same `Engraver` layout as the
/// on-screen page.
enum AudioExporter {
    /// Render the score with the bundled SoundFont and encode to MP3.
    /// The heavy work (synth render + LAME) runs off the main thread.
    static func mp3Data(for score: QuantizedScore) async throws -> Data {
        let soundFont = try await BundledModels.soundFont()
        return try await Task.detached(priority: .userInitiated) {
            let midi = MIDISupport.data(for: score)
            // .spec = the same SoundFont 2.04 rules SF2MIDIPlayer plays with.
            let stereo = try SF2OfflineRenderer.render(midi: midi, soundFont: soundFont,
                                                       sampleRate: 44100, tailSec: 2, fidelity: .spec)
            var interleaved = [Float](repeating: 0, count: stereo.length * 2)
            for i in 0..<stereo.length {
                interleaved[2 * i] = stereo.left[i]
                interleaved[2 * i + 1] = stereo.right[i]
            }
            return try MP3Encoder.encode(interleaved: interleaved, sampleRate: 44100, channels: 2)
        }.value
    }
}

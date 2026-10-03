// SPDX-License-Identifier: AGPL-3.0-or-later
import CLAME
import Foundation

/// Minimal MP3 encoder over the vendored LAME 3.100 C library
/// (see Packages/LAME/VENDOR.md). iOS has no system MP3 encoder.
enum MP3Encoder {
    enum EncodeError: Error, CustomStringConvertible {
        case initFailed
        case paramsFailed
        case encodeFailed
        var description: String {
            switch self {
            case .initFailed: "Could not start the MP3 encoder."
            case .paramsFailed: "Could not configure the MP3 encoder."
            case .encodeFailed: "MP3 encoding failed."
            }
        }
    }

    /// - Parameters:
    ///   - interleaved: float PCM, -1...1, channels interleaved.
    ///   - sampleRate: e.g. 44100. LAME supports 8000...48000.
    ///   - channels: 1 or 2.
    ///   - bitrateKbps: CBR bitrate (128 default).
    /// - Returns: MP3 file bytes.
    static func encode(interleaved: [Float], sampleRate: Int, channels: Int,
                       bitrateKbps: Int = 128) throws -> Data {
        guard let gfp = lame_init() else { throw EncodeError.initFailed }
        defer { lame_close(gfp) }
        lame_set_in_samplerate(gfp, Int32(sampleRate))
        lame_set_num_channels(gfp, Int32(channels))
        lame_set_brate(gfp, Int32(bitrateKbps))
        lame_set_quality(gfp, 2) // high quality, still fast
        guard lame_init_params(gfp) == 0 else { throw EncodeError.paramsFailed }

        var out = Data()
        // LAME docs: mp3buf should be at least 1.25 * nsamples + 7200.
        let chunk = 8192
        var mp3buf = [UInt8](repeating: 0, count: Int(1.25 * Double(chunk)) + 7200)
        let totalFrames = interleaved.count / channels
        var done = 0
        while done < totalFrames {
            let n = min(chunk, totalFrames - done)
            let written = interleaved.withUnsafeBufferPointer { pcm -> Int32 in
                let base = pcm.baseAddress! + done * channels
                return mp3buf.withUnsafeMutableBufferPointer { mp3 -> Int32 in
                    lame_encode_buffer_interleaved_ieee_float(
                        gfp, base, Int32(n), mp3.baseAddress!, Int32(mp3.count))
                }
            }
            guard written >= 0 else { throw EncodeError.encodeFailed }
            out.append(contentsOf: mp3buf.prefix(Int(written)))
            done += n
        }
        let flushed = mp3buf.withUnsafeMutableBufferPointer { mp3 -> Int32 in
            lame_encode_flush(gfp, mp3.baseAddress!, Int32(mp3.count))
        }
        guard flushed >= 0 else { throw EncodeError.encodeFailed }
        out.append(contentsOf: mp3buf.prefix(Int(flushed)))
        return out
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Writes 16-bit PCM mono WAV data from float32 samples in [-1, 1].
/// Used by the record-session debug export (mic audio as the model heard it).
public enum WavWriter {
    public static func data(samples: [Float], sampleRate: Int) -> Data {
        var out = Data()
        out.reserveCapacity(44 + samples.count * 2)
        func appendU32(_ v: UInt32) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
            out.append(UInt8((v >> 16) & 0xFF)); out.append(UInt8((v >> 24) & 0xFF))
        }
        func appendU16(_ v: UInt16) {
            out.append(UInt8(v & 0xFF)); out.append(UInt8((v >> 8) & 0xFF))
        }
        let dataBytes = samples.count * 2
        out.append(contentsOf: "RIFF".utf8); appendU32(UInt32(36 + dataBytes))
        out.append(contentsOf: "WAVE".utf8)
        out.append(contentsOf: "fmt ".utf8); appendU32(16)
        appendU16(1) // PCM
        appendU16(1) // mono
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 2)) // byte rate
        appendU16(2) // block align
        appendU16(16) // bits per sample
        out.append(contentsOf: "data".utf8); appendU32(UInt32(dataBytes))
        for s in samples {
            let clamped = max(-1, min(1, s))
            appendU16(UInt16(bitPattern: Int16((clamped * 32767).rounded())))
        }
        return out
    }
}

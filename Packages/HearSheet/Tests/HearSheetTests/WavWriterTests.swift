// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

final class WavWriterTests: XCTestCase {
    private func u32LE(_ data: Data, at i: Int) -> UInt32 {
        UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
    }
    private func i16LE(_ data: Data, at i: Int) -> Int16 {
        Int16(bitPattern: UInt16(data[i]) | UInt16(data[i + 1]) << 8)
    }

    func testHeaderAndRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let data = WavWriter.data(samples: samples, sampleRate: 22050)
        // 44-byte header + 5 samples * 2 bytes.
        XCTAssertEqual(data.count, 54)
        XCTAssertEqual(String(data: data[0..<4], encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data[12..<16], encoding: .ascii), "fmt ")
        XCTAssertEqual(String(data: data[36..<40], encoding: .ascii), "data")
        XCTAssertEqual(u32LE(data, at: 24), 22050, "sample rate")
        XCTAssertEqual(u32LE(data, at: 40), 10, "data chunk size")
        XCTAssertEqual(i16LE(data, at: 44), 0)
        XCTAssertEqual(i16LE(data, at: 50), 32767)
        XCTAssertEqual(i16LE(data, at: 52), -32767)
        XCTAssertEqual(Double(i16LE(data, at: 46)) / 32767, 0.5, accuracy: 1.0 / 32767)
        XCTAssertEqual(Double(i16LE(data, at: 48)) / 32767, -0.5, accuracy: 1.0 / 32767)
    }

    func testClampsOutOfRange() {
        let data = WavWriter.data(samples: [2.0, -2.0], sampleRate: 22050)
        XCTAssertEqual(i16LE(data, at: 44), 32767)
        XCTAssertEqual(i16LE(data, at: 46), -32767)
    }

    func testEmpty() {
        let data = WavWriter.data(samples: [], sampleRate: 22050)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(u32LE(data, at: 40), 0)
    }
}

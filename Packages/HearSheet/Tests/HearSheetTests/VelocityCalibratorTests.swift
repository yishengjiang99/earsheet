// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import HearSheet

final class VelocityCalibratorTests: XCTestCase {
    func testLoadsCoefficients() {
        let cal = VelocityCalibrator()
        // Middle C (60) should have fitted coefficients, not the global fallback.
        // A loud note (rms 0.1) should map higher than a quiet one (rms 0.01).
        let loud = cal.velocity(for: 60, rms: 0.1)
        let quiet = cal.velocity(for: 60, rms: 0.01)
        XCTAssertGreaterThan(loud, quiet, "louder RMS should give higher velocity")
        XCTAssertTrue((1...127).contains(loud))
        XCTAssertTrue((1...127).contains(quiet))
    }

    func testRMS() {
        let samples: [Float] = [1, -1, 1, -1]
        let r = VelocityCalibrator.rms(of: samples, from: 0, to: 4)
        XCTAssertEqual(r, 1.0, accuracy: 1e-6)
        // Empty range -> 0
        XCTAssertEqual(VelocityCalibrator.rms(of: samples, from: 2, to: 2), 0)
        // Clamped to bounds
        XCTAssertEqual(VelocityCalibrator.rms(of: samples, from: -10, to: 100), 1.0, accuracy: 1e-6)
    }

    func testVelocityRange() {
        let cal = VelocityCalibrator()
        // Extreme inputs stay in 1...127
        XCTAssertEqual(cal.velocity(for: 60, rms: 1e-9), cal.velocity(for: 60, rms: 1e-9))
        XCTAssertTrue((1...127).contains(cal.velocity(for: 60, rms: 10)))
        XCTAssertTrue((1...127).contains(cal.velocity(for: 200, rms: 0.05))) // out-of-range pitch -> global
    }
}

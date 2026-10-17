// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
import HearSheet
@testable import EarSheet

/// Settings screen logic (#14, #25).
final class SettingsTests: XCTestCase {
    func testGoProRowRoutesByEntitlement() {
        XCTAssertEqual(SettingsView.goProRoute(isPro: true), .manage)
        XCTAssertEqual(SettingsView.goProRoute(isPro: false), .paywall)
    }

    // MARK: - Measure now (#25)

    private final class FakeRecorder: FloorRecorder {
        let floor: Double?
        let defaults: UserDefaults
        var startError: Error?
        private(set) var started = false
        init(floor: Double?, defaults: UserDefaults, startError: Error? = nil) {
            self.floor = floor; self.defaults = defaults; self.startError = startError
        }
        func start() throws {
            if let startError { throw startError }
            started = true
        }
        /// Like AudioRecorder.stop(): persists whatever floor it measured.
        func stop() -> [Float] {
            if let floor {
                defaults.set(floor, forKey: InputConditioner.Settings.Keys.lastFloorDB)
                defaults.set(999.0, forKey: InputConditioner.Settings.Keys.lastFloorAt)
            }
            return []
        }
        var noiseFloorDB: Double? { floor }
    }

    private struct StartFailure: Error {}

    private let dbKey = InputConditioner.Settings.Keys.lastFloorDB
    private let atKey = InputConditioner.Settings.Keys.lastFloorAt

    private func freshDefaults() -> UserDefaults {
        let name = "SettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @MainActor
    private func meter(_ defaults: UserDefaults, permission: MicPermission, grantOnRequest: Bool = false,
                       recorder: FakeRecorder?) -> NoiseFloorMeter {
        NoiseFloorMeter(permission: { permission }, requestPermission: { grantOnRequest },
                        makeRecorder: {
                            guard let recorder else { XCTFail("recorder must not be created without permission"); return FakeRecorder(floor: nil, defaults: defaults) }
                            return recorder
                        },
                        defaults: defaults, duration: 0)
    }

    @MainActor
    func testMeasureFloorDeniedDoesNotWriteFloor() async {
        let d = freshDefaults()
        d.set(-62.0, forKey: dbKey)
        d.set(123.0, forKey: atKey)
        let outcome = await meter(d, permission: .denied, recorder: nil).measure()
        XCTAssertEqual(outcome, .permissionDenied)
        XCTAssertEqual(d.double(forKey: dbKey), -62.0)
        XCTAssertEqual(d.double(forKey: atKey), 123.0)
        XCTAssertNotNil(NoiseFloorMeter.message(for: outcome))

        // Undetermined and the user declines the system prompt: same.
        let declined = await meter(d, permission: .undetermined, grantOnRequest: false, recorder: nil).measure()
        XCTAssertEqual(declined, .permissionDenied)
        XCTAssertEqual(d.double(forKey: dbKey), -62.0)
    }

    @MainActor
    func testMeasureFloorSilentInputKeepsPreviousFloor() async {
        let d = freshDefaults()
        d.set(-62.0, forKey: dbKey)
        d.set(123.0, forKey: atKey)
        let silent = FakeRecorder(floor: -90, defaults: d)
        let outcome = await meter(d, permission: .granted, recorder: silent).measure()
        XCTAssertEqual(outcome, .tooQuiet)
        XCTAssertEqual(d.double(forKey: dbKey), -62.0, "a digital-silence reading must not replace the stored floor")
        XCTAssertEqual(d.double(forKey: atKey), 123.0)

        // Never measured before: the bogus value is removed, "Not measured yet" stays.
        let fresh = freshDefaults()
        let outcome2 = await meter(fresh, permission: .granted, recorder: FakeRecorder(floor: -90, defaults: fresh)).measure()
        XCTAssertEqual(outcome2, .tooQuiet)
        XCTAssertNil(fresh.object(forKey: dbKey))
        XCTAssertNil(fresh.object(forKey: atKey))
    }

    @MainActor
    func testMeasureFloorStoresRealReading() async {
        let d = freshDefaults()
        let outcome = await meter(d, permission: .granted, recorder: FakeRecorder(floor: -61.5, defaults: d)).measure()
        XCTAssertEqual(outcome, .measured)
        XCTAssertEqual(d.double(forKey: dbKey), -61.5)
        XCTAssertNil(NoiseFloorMeter.message(for: outcome))

        // Undetermined and granted at the prompt: measures.
        let d2 = freshDefaults()
        let outcome2 = await meter(d2, permission: .undetermined, grantOnRequest: true,
                                   recorder: FakeRecorder(floor: -70, defaults: d2)).measure()
        XCTAssertEqual(outcome2, .measured)
        XCTAssertEqual(d2.double(forKey: dbKey), -70)
    }

    @MainActor
    func testMeasureFloorStartFailureIsReported() async {
        let d = freshDefaults()
        d.set(-62.0, forKey: dbKey)
        let failing = FakeRecorder(floor: nil, defaults: d, startError: StartFailure())
        let outcome = await meter(d, permission: .granted, recorder: failing).measure()
        XCTAssertEqual(outcome, .couldNotStart)
        XCTAssertEqual(d.double(forKey: dbKey), -62.0)
        XCTAssertEqual(NoiseFloorMeter.message(for: outcome), NoiseFloorMeter.couldNotStartMessage)
    }
}

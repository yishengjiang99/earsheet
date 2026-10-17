// SPDX-License-Identifier: AGPL-3.0-or-later
import AVFAudio
import Foundation
import HearSheet

/// What `NoiseFloorMeter` needs from the recorder (`AudioRecorder` in the app, a fake in tests).
protocol FloorRecorder: AnyObject {
    func start() throws
    func stop() -> [Float]
    var noiseFloorDB: Double? { get }
}

extension AudioRecorder: FloorRecorder {}

enum MicPermission: Equatable {
    case granted, denied, undetermined

    static func current() -> MicPermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .undetermined: return .undetermined
        default: return .denied
        }
    }

    static func request() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }
}

/// Settings › Microphone › "Measure now": checks microphone permission first, reports every failure,
/// and never leaves a bogus floor behind (a denied or silent mic delivers digital silence, which
/// reads as the -90 dBFS clamp and would push the auto gate threshold to its minimum).
@MainActor
struct NoiseFloorMeter {
    enum Outcome: Equatable {
        case measured
        case permissionDenied
        case couldNotStart
        case tooQuiet
    }

    /// Digital silence reads -90 (the estimator's lower clamp); no real microphone is that quiet.
    static let silenceFloorDB = -89.5
    static let deniedMessage = "Microphone access is off for AI Music Radar. Turn it on in iOS Settings to measure the room."
    static let couldNotStartMessage = "Couldn't start the microphone. Close other audio apps and try again."
    static let tooQuietMessage = "The microphone only picked up silence, so the noise floor wasn't saved. Make sure the microphone isn't covered and try again."

    var permission: () -> MicPermission = { MicPermission.current() }
    var requestPermission: () async -> Bool = { await MicPermission.request() }
    var makeRecorder: () -> any FloorRecorder = { AudioRecorder() }
    var defaults: UserDefaults = .standard
    var duration: TimeInterval = 1.2

    static func message(for outcome: Outcome) -> String? {
        switch outcome {
        case .measured: return nil
        case .permissionDenied: return deniedMessage
        case .couldNotStart: return couldNotStartMessage
        case .tooQuiet: return tooQuietMessage
        }
    }

    /// Listens for `duration` seconds (stay quiet). The recorder stores the floor it measured; it is
    /// kept only when it is a real reading, otherwise the previous value is put back.
    func measure() async -> Outcome {
        var status = permission()
        if status == .undetermined {
            status = await requestPermission() ? .granted : .denied
        }
        guard status == .granted else { return .permissionDenied }

        let dbKey = InputConditioner.Settings.Keys.lastFloorDB
        let atKey = InputConditioner.Settings.Keys.lastFloorAt
        let previousDB = defaults.object(forKey: dbKey)
        let previousAt = defaults.object(forKey: atKey)

        let recorder = makeRecorder()
        do {
            try recorder.start()
        } catch {
            return .couldNotStart
        }
        try? await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
        let floor = recorder.noiseFloorDB
        _ = recorder.stop() // saves the measured floor to UserDefaults (shown in Settings)
        // The recorder saves via DispatchQueue.main.async; let those writes land before judging them.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }

        guard let floor, floor > Self.silenceFloorDB else {
            Self.put(previousDB, forKey: dbKey, in: defaults)
            Self.put(previousAt, forKey: atKey, in: defaults)
            return .tooQuiet
        }
        return .measured
    }

    private static func put(_ value: Any?, forKey key: String, in defaults: UserDefaults) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

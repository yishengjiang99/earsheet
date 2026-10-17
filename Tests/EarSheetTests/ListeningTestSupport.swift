// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import HearSheet
@testable import EarSheet

/// Recorder stand-in: records calls, produces whatever samples the test sets.
final class FakeRecorder: Recording {
    var onSamples: (([Float]) -> Void)?
    var onLevel: ((Float) -> Void)?
    var recordedSeconds: Double = 0
    var currentSamples: [Float] = []
    var gateThresholdDB: Double = -60
    private(set) var startCount = 0
    private(set) var stopCount = 0
    var startError: Error?
    /// Returned by `stop()`.
    var samplesToReturn: [Float] = []

    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stop() -> [Float] {
        stopCount += 1
        return samplesToReturn
    }
}

/// Mutable microphone-permission answer for `requestMicPermission`.
final class PermissionFlag: @unchecked Sendable {
    var granted: Bool
    init(_ granted: Bool) { self.granted = granted }
}

@MainActor
enum ListeningTestSupport {
    /// A session wired to a fake recorder, a granted/denied permission and no model.
    static func makeSession(recorder: FakeRecorder = FakeRecorder(), permission: PermissionFlag = PermissionFlag(true),
                            library: TakeLibrary? = nil) -> ListeningSession {
        ListeningSession(library: library ?? TakeLibrary(), proStore: ProStore(), triggers: PaywallTriggers(),
                         recorder: recorder,
                         requestMicPermission: { permission.granted },
                         loadModel: { nil })
    }

    /// Starts the session and waits until warm-up finished.
    static func startAndWait(_ session: ListeningSession) async {
        session.start()
        await session.startTask?.value
    }

    /// Number of .wav files in the library's audio directory (the default Application Support one).
    static func wavFileCount() -> Int {
        let dir = TakeLibrary.audioURL(fileName: "probe.wav").deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".wav") }.count
    }
}

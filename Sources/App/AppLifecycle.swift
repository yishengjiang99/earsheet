// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit

/// Launch / foreground / background wiring for StoreKit, the server and telemetry.
/// Everything here is best-effort: the app is fully usable offline.
@MainActor
enum AppLifecycle {
    private static var launched = false
    private static var lastHeartbeat: Date?
    private static let lastVersionKey = "AppLifecycle.lastRegisteredVersion"

    /// Skips network work in unit-test hosts (XCTest) and when `MUSIC_RADAR_OFFLINE=1`.
    static var isOffline: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["MUSIC_RADAR_OFFLINE"] == "1"
    }

    static func didLaunch() {
        guard !launched else { return }
        launched = true
        guard !isOffline else { return }
        ProStore.shared.start()
        Telemetry.shared.start()
        Telemetry.shared.track(.appOpen, ["cold": true])
    }

    static func didBecomeActive() {
        guard !isOffline else { return }
        Telemetry.shared.appDidBecomeActive()
        heartbeat()
        Task {
            await PushManager.shared.refresh()
            await ProStore.shared.flushPendingVerifications()
            await ProStore.shared.refreshEntitlements()
        }
    }

    static func didEnterBackground() {
        guard !isOffline else { return }
        let task = BackgroundTask(name: "telemetry-flush")
        Telemetry.shared.appDidEnterBackground {
            Task { @MainActor in task.end() }
        }
    }

    /// `POST /api/devices/register` on launch, on version change and at most every 6 h on foreground.
    private static func heartbeat() {
        let version = "\(AppConfig.appVersion) (\(AppConfig.buildNumber))"
        let changed = UserDefaults.standard.string(forKey: lastVersionKey) != version
        if !changed, let last = lastHeartbeat, Date().timeIntervalSince(last) < 6 * 3600 { return }
        lastHeartbeat = Date()
        let info = APIClient.DeviceInfo.current()
        Task {
            if (try? await APIClient.shared.registerDevice(info)) != nil {
                UserDefaults.standard.set(version, forKey: lastVersionKey)
            }
        }
    }
}

/// One UIKit background task, ended exactly once (by completion or expiry).
@MainActor
private final class BackgroundTask: @unchecked Sendable {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

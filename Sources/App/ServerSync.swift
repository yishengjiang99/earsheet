// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit

/// App lifecycle wiring for the backend: device heartbeat, telemetry flush and the IAP
/// verify retry queue. Everything is best-effort; the app is fully usable offline.
///
/// Heartbeat = `POST /api/devices/register` (the server has no separate heartbeat route;
/// re-registering updates `last_seen_at`), then flush telemetry, then drain the verify queue.
/// It runs on every foreground and every 5 minutes while the app is active.
@MainActor
final class ServerSync {
    static let shared = ServerSync()
    static let heartbeatInterval: TimeInterval = 5 * 60

    private let client: APIClient
    private let telemetry: Telemetry
    private let verifyQueue: VerifyQueue
    private let deviceInfo: @MainActor () -> APIClient.DeviceInfo
    private var timer: Timer?
    private var launched = false

    init(client: APIClient = .shared, telemetry: Telemetry = .shared, verifyQueue: VerifyQueue = .shared,
         deviceInfo: @escaping @MainActor () -> APIClient.DeviceInfo = { ServerSync.currentDeviceInfo() }) {
        self.client = client
        self.telemetry = telemetry
        self.verifyQueue = verifyQueue
        self.deviceInfo = deviceInfo
    }

    /// No network from unit-test hosts or with `MUSIC_RADAR_OFFLINE=1`.
    nonisolated static var isDisabledInThisProcess: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["MUSIC_RADAR_OFFLINE"] == "1"
    }

    func heartbeat() async {
        try? await client.registerDevice(deviceInfo())
        await telemetry.flush()
        await verifyQueue.drain()
    }

    // MARK: - Lifecycle (called from EarSheetApp)

    func appDidBecomeActive() {
        guard !Self.isDisabledInThisProcess else { return }
        if !launched {
            launched = true
            telemetry.track(.appOpen, ["cold": true])
        }
        telemetry.appDidBecomeActive()
        Task {
            await PushManager.shared.refresh()
            await heartbeat()
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.heartbeatInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.heartbeat() }
        }
    }

    func appDidEnterBackground() {
        guard !Self.isDisabledInThisProcess else { return }
        timer?.invalidate()
        timer = nil
        telemetry.appDidEnterBackground()
        let task = BackgroundTask(name: "server-sync")
        let telemetry = self.telemetry
        let queue = self.verifyQueue
        Task {
            await telemetry.flush()
            await queue.drain()
            task.end()
        }
    }

    // MARK: - Transactions (called by ProStore)

    /// Queue a verified StoreKit transaction for `/api/iap/verify`, then try to send it now.
    /// Uses the token Apple stamped into the transaction (it may come from another device on
    /// restore; the server rejects a mismatching token), else this install's token.
    nonisolated static func report(_ transactionId: UInt64, _ transactionToken: UUID?, _ signedTransaction: String) {
        let token = transactionToken?.uuidString.lowercased() ?? InstallIdentity.appAccountTokenString
        Task {
            await VerifyQueue.shared.enqueue(transactionId: String(transactionId),
                                             signedTransaction: signedTransaction, appAccountToken: token)
            guard !isDisabledInThisProcess else { return }
            await VerifyQueue.shared.drain()
        }
    }

    // MARK: - Device info

    static func currentDeviceInfo() -> APIClient.DeviceInfo {
        let info = Bundle.main.infoDictionary
        return APIClient.DeviceInfo(
            installId: InstallIdentity.installIdString,
            appAccountToken: InstallIdentity.appAccountTokenString,
            osVersion: UIDevice.current.systemVersion,
            appVersion: info?["CFBundleShortVersionString"] as? String ?? "0",
            buildNumber: info?["CFBundleVersion"] as? String ?? "0",
            deviceModel: hardwareModel(),
            locale: Locale.current.identifier,
            timezone: TimeZone.current.identifier)
    }

    /// Model identifier such as "iPhone17,1" (never the user-assigned device name).
    nonisolated static func hardwareModel() -> String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

/// One UIKit background task, ended exactly once (by completion or expiry).
@MainActor
private final class BackgroundTask {
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

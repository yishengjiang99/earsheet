// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit
import UserNotifications

/// Notification authorization, seam for tests.
protocol NotificationAuthorizing {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
}

struct SystemNotificationCenter: NotificationAuthorizing {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
    func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
}

/// APNs registration with the server (docs/iap/IOS_INTEGRATION.md §8).
///
/// Permission policy: the system prompt appears only when the user turns on the
/// Notifications toggle in Settings. Launch, foreground and recording never prompt:
/// `refresh()` only reads the current status and, if the user already allowed
/// notifications and left the toggle on, re-registers so a rotated token reaches the server.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// The Settings toggle (off by default).
    @Published private(set) var enabledInApp: Bool

    static let enabledKey = "push.enabled"
    static let tokenKey = "push.registeredToken"

    private let center: NotificationAuthorizing
    private let client: APIClient
    private let defaults: UserDefaults
    private let registerRemote: () -> Void
    private let unregisterRemote: () -> Void

    init(center: NotificationAuthorizing = SystemNotificationCenter(),
         client: APIClient = .shared,
         defaults: UserDefaults = .standard,
         registerRemote: @escaping () -> Void = { UIApplication.shared.registerForRemoteNotifications() },
         unregisterRemote: @escaping () -> Void = { UIApplication.shared.unregisterForRemoteNotifications() }) {
        self.center = center
        self.client = client
        self.defaults = defaults
        self.registerRemote = registerRemote
        self.unregisterRemote = unregisterRemote
        self.enabledInApp = defaults.bool(forKey: Self.enabledKey)
    }

    /// `sandbox` for Debug (Xcode, development APNs), `production` for TestFlight / App Store.
    static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    var isAllowedBySystem: Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Launch / foreground. Never prompts.
    func refresh() async {
        status = await center.authorizationStatus()
        if enabledInApp && isAllowedBySystem { registerRemote() }
    }

    /// Settings toggle on (an explicit user action): ask once if undetermined, then register.
    @discardableResult
    func enable() async -> Bool {
        var s = await center.authorizationStatus()
        if s == .notDetermined {
            _ = try? await center.requestAuthorization()
            s = await center.authorizationStatus()
        }
        status = s
        enabledInApp = isAllowedBySystem
        defaults.set(enabledInApp, forKey: Self.enabledKey)
        if enabledInApp { registerRemote() }
        return enabledInApp
    }

    /// Settings toggle off: stop pushes for this install on the server and locally.
    func disable() async {
        enabledInApp = false
        defaults.set(false, forKey: Self.enabledKey)
        unregisterRemote()
        if let token = defaults.string(forKey: Self.tokenKey) {
            try? await client.unregisterPush(installId: InstallIdentity.installIdString, token: token)
            defaults.removeObject(forKey: Self.tokenKey)
        }
    }

    // MARK: - AppDelegate callbacks

    func didRegister(deviceToken: Data) async {
        guard enabledInApp else { return }
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        let previous = defaults.string(forKey: Self.tokenKey)
        let installId = InstallIdentity.installIdString
        do {
            try await client.registerPush(installId: installId, token: hex, environment: Self.apnsEnvironment)
            defaults.set(hex, forKey: Self.tokenKey)
            if let previous, previous != hex {
                try? await client.unregisterPush(installId: installId, token: previous)
            }
        } catch {
            // Retried on the next foreground via refresh() -> registerForRemoteNotifications.
        }
    }
}

/// UIKit hooks SwiftUI doesn't expose: the APNs token callbacks.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected on the simulator and in builds signed without the Push entitlement.
    }
}

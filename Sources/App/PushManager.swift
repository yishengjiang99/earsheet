// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import UIKit
import UserNotifications

/// Notification permission, APNs token registration with the server, and the local
/// trial-ending reminder (docs/iap/IOS_INTEGRATION.md §8).
///
/// Permission is never asked at launch. The prompts are: "Turn on trial reminder" after a trial
/// starts, and the Notifications toggle in Settings. Remote registration needs the
/// `aps-environment` entitlement (Sources/EarSheet.entitlements); builds signed without it get
/// `didFailToRegister…`, which is logged and otherwise ignored.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var lastError: String?

    private static let tokenKey = "PushManager.apnsToken"
    private static let optOutKey = "PushManager.optedOut"
    private let api: APIClient

    init(api: APIClient = .shared) { self.api = api }

    /// The hex token last registered with the server.
    var registeredToken: String? { UserDefaults.standard.string(forKey: Self.tokenKey) }

    /// User turned notifications off in Settings (we unregister and don't re-register).
    var optedOut: Bool { UserDefaults.standard.bool(forKey: Self.optOutKey) }

    var isEnabled: Bool {
        !optedOut && (authorization == .authorized || authorization == .provisional || authorization == .ephemeral)
    }

    static var apnsEnvironment: String {
        #if DEBUG
        "sandbox"     // Xcode builds → development APNs
        #else
        "production"  // TestFlight + App Store → production APNs
        #endif
    }

    /// Launch / foreground: refresh status; if already allowed, re-register so a rotated token
    /// reaches the server. Never prompts.
    func refresh() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if isEnabled { UIApplication.shared.registerForRemoteNotifications() }
    }

    /// Asks for permission (only if undetermined) and registers for remote notifications.
    /// - Returns: whether notifications are allowed.
    @discardableResult
    func requestPermission() async -> Bool {
        UserDefaults.standard.set(false, forKey: Self.optOutKey)
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            Telemetry.shared.track(.pushPermissionPrompt)
            let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
            Telemetry.shared.track(granted ? .pushPermissionGranted : .pushPermissionDenied)
            status = await center.notificationSettings().authorizationStatus
        }
        authorization = status
        if isEnabled { UIApplication.shared.registerForRemoteNotifications() }
        return isEnabled
    }

    /// Settings toggle off: stop remote pushes for this install.
    func disable() async {
        UserDefaults.standard.set(true, forKey: Self.optOutKey)
        UIApplication.shared.unregisterForRemoteNotifications()
        if let token = registeredToken {
            try? await api.unregisterPush(token: token)
            UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        }
    }

    // MARK: - AppDelegate callbacks

    func didRegister(deviceToken: Data) {
        let hex = Self.hex(deviceToken)
        guard !optedOut else { return }
        lastError = nil
        let previous = registeredToken
        Task {
            do {
                try await api.registerPush(token: hex, environment: Self.apnsEnvironment)
                UserDefaults.standard.set(hex, forKey: Self.tokenKey)
                if let previous, previous != hex { try? await api.unregisterPush(token: previous) }
            } catch {
                lastError = String(describing: error)
            }
        }
    }

    func didFailToRegister(_ error: Error) {
        // Expected while the build is signed without the Push entitlement.
        lastError = (error as NSError).localizedDescription
        let ns = error as NSError
        Telemetry.shared.track(.error, ["domain": "apns_register", "code": ns.code])
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Trial reminder (local notification)

    static let trialReminderID = "trial-ending-reminder"

    /// Asks for permission, then schedules "your trial ends in 2 days" before `trialEnds`.
    func scheduleTrialReminder(trialEnds: Date) async -> Bool {
        guard await requestPermission() else { return false }
        let fire = trialEnds.addingTimeInterval(-2 * 86400)
        guard fire > Date() else { return false }
        let content = UNMutableNotificationContent()
        content.title = "Your AI Music Radar trial ends soon"
        content.body = "Pro renews on \(trialEnds.formatted(date: .abbreviated, time: .omitted)). Cancel anytime in Settings › Apple ID › Subscriptions."
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let req = UNNotificationRequest(identifier: Self.trialReminderID, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do {
            try await UNUserNotificationCenter.current().add(req)
            return true
        } catch {
            return false
        }
    }
}

/// UIKit hooks SwiftUI doesn't expose: APNs token callbacks and foreground presentation.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFailToRegister(error) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct EarSheetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppLifecycle.didLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: AppLifecycle.didBecomeActive()
            case .background: AppLifecycle.didEnterBackground()
            default: break
            }
        }
    }
}

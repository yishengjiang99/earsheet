// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

@main
struct EarSheetApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: ServerSync.shared.appDidBecomeActive()
            case .background: ServerSync.shared.appDidEnterBackground()
            default: break
            }
        }
    }
}

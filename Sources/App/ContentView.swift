// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// App root: first-launch onboarding, then the take library.
struct ContentView: View {
    @StateObject private var library = TakeLibrary()
    @StateObject private var proStore = ProStore()
    @StateObject private var triggers = PaywallTriggers()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        Group {
            if hasSeenOnboarding {
                LibraryView(library: library, proStore: proStore, triggers: triggers)
            } else {
                OnboardingView(onDone: { hasSeenOnboarding = true })
            }
        }
        .environment(\.paywallTriggers, triggers)
        .preferredColorScheme(.light)
        .task {
            await proStore.refreshEntitlement()
            triggers.resetSession()
        }
        .onChange(of: scenePhase) { _, phase in
            // A lapsed subscription must lock Pro on the next foreground, not on the next launch.
            if phase == .active { Task { await proStore.refreshEntitlement() } }
        }
    }
}

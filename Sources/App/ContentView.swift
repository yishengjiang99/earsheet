// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// App root: first-launch onboarding, then the take library.
struct ContentView: View {
    @StateObject private var library = TakeLibrary()
    @StateObject private var proStore = ProStore()
    @StateObject private var triggers = PaywallTriggers()
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false

    var body: some View {
        Group {
            if hasSeenOnboarding {
                LibraryView(library: library, proStore: proStore, triggers: triggers)
            } else {
                OnboardingView(onDone: { hasSeenOnboarding = true })
            }
        }
        .preferredColorScheme(.light)
        .task {
            await proStore.refreshEntitlement()
            triggers.resetSession()
        }
    }
}

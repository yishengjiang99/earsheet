// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

private struct PaywallTriggersKey: EnvironmentKey {
    static var defaultValue: PaywallTriggers? { nil }
}

extension EnvironmentValues {
    /// The app's shared upgrade-prompt state (caps history, session). Set once at the root so deep
    /// screens (Export) use the same session counter as the Library; nil in previews and tests.
    var paywallTriggers: PaywallTriggers? {
        get { self[PaywallTriggersKey.self] }
        set { self[PaywallTriggersKey.self] = newValue }
    }
}

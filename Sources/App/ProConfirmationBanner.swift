// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// One-line banner under the navigation bar ("Pro is on. Trial ends Oct 24."), cleared after a few seconds.
private struct ProConfirmationBanner: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let message {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text(message).font(.subheadline.weight(.semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Ink.teal)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("pro.confirmation")
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.25), value: message)
            .task(id: message) {
                guard message != nil else { return }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if !Task.isCancelled { message = nil }
            }
    }
}

extension View {
    func proConfirmationBanner(_ message: Binding<String?>) -> some View {
        modifier(ProConfirmationBanner(message: message))
    }
}

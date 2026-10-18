// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Inline card at the top of My Takes. Tapping it opens the paywall (a tap: never counted);
/// × dismisses it through the shared policy.
struct ThirdTakeCardView: View {
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "crown.fill")
                        .foregroundStyle(Ink.teal)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ThirdTakeCard.title)
                            .font(.headline)
                            .foregroundStyle(Ink.ink)
                        Text(ThirdTakeCard.body)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Text(ThirdTakeCard.actionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.teal)
                            .padding(.top, 2)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("thirdTake.card")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("thirdTake.dismiss")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.teal.opacity(0.08)))
        .padding(.vertical, 4)
    }
}

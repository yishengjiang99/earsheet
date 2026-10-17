// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Library row for `SaveQuotaSummary`. Tapping is only possible at the limit (opens the plans).
struct SaveMeterRow: View {
    let summary: SaveQuotaSummary
    let onOpenPlans: () -> Void

    var body: some View {
        if let action = summary.actionTitle {
            Button(action: onOpenPlans) { content(action: action) }
                .buttonStyle(.plain)
                .accessibilityHint("Opens Pro plans")
                .accessibilityIdentifier("saveMeter.row")
        } else {
            content(action: nil)
                .accessibilityIdentifier("saveMeter.row")
        }
    }

    private func content(action: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.text)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Ink.ink)
                if let note = summary.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let action {
                Text(action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Ink.teal)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Ink.teal)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.accessibilityLabel)
    }
}

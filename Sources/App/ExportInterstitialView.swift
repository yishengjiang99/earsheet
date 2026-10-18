// SPDX-License-Identifier: AGPL-3.0-or-later
import HearSheet
import SwiftUI

/// Half-height sheet over the take: the user's own score with Pro formats locked, "Try Pro" and a
/// free PDF alternative. A visible close button from the first frame; swipe-down also closes.
struct ExportInterstitialView: View {
    let take: Take
    let score: QuantizedScore
    @ObservedObject var proStore: ProStore
    let onSeePlans: () -> Void
    let onFreePDF: () -> Void
    let onClose: () -> Void

    private var trialText: String? {
        proStore.products.compactMap { proStore.eligibleTrial(for: $0)?.period.trialText }.first
    }

    /// The user's own first bars; the rest of the page is faded away.
    private var previewScore: QuantizedScore {
        var s = score
        let cutoff16 = Int(8.0 / s.secondsPer16th)
        s.notes = s.notes.filter { $0.start16 < cutoff16 }
        return s
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your score is ready")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Ink.teal)
                        .textCase(.uppercase)
                    StaffPageView(score: previewScore, highlighted: [])
                        .frame(height: 150)
                        .clipped()
                        .mask(LinearGradient(colors: [.black, .black, .clear], startPoint: .top, endPoint: .bottom))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    HStack(spacing: 8) {
                        lockPill("MIDI")
                        lockPill("MusicXML")
                    }
                    Text(ExportInterstitialFlow.headline)
                        .font(.system(.title2, design: .serif))
                        .fontWeight(.bold)
                    Text(ExportInterstitialFlow.body(title: take.title, trialText: trialText))
                        .foregroundStyle(.secondary)
                    Button(action: {
                        Telemetry.shared.track(.softPromptTapped, ["kind": "export"])
                        onSeePlans()
                    }) {
                        Text(ExportInterstitialFlow.primaryTitle(trialText: trialText))
                            .font(.system(.headline, design: .serif))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Ink.teal))
                    }
                    .accessibilityIdentifier("exportInterstitial.tryPro")
                    Text(ExportInterstitialFlow.footnote)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                    Button(ExportInterstitialFlow.freePDFTitle) {
                        Telemetry.shared.track(.softPromptDismissed, ["kind": "export", "result": "free"])
                        onFreePDF()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("exportInterstitial.freePDF")
                }
                .padding(24)
            }
            .background(Ink.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: {
                        Telemetry.shared.track(.softPromptDismissed, ["kind": "export", "result": "close"])
                        onClose()
                    }) {
                        Image(systemName: "xmark").font(.headline)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task { await proStore.loadProducts() }
            .onAppear { Telemetry.shared.track(.softPromptShown, ["kind": "export"]) }
            .onChange(of: proStore.isPro) { _, isPro in
                if isPro { onClose() }
            }
        }
        .presentationDetents([.large, .medium])
    }

    private func lockPill(_ title: String) -> some View {
        Label(title, systemImage: "lock.fill")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Ink.teal.opacity(0.12)))
            .foregroundStyle(Ink.teal)
    }
}

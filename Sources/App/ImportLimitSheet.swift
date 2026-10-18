// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

/// Half-height sheet shown before a long import is transcribed. "Try Pro" opens the full paywall
/// from here (a tap, so it never counts toward the automatic-prompt caps).
struct ImportLimitSheet: View {
    let durationSeconds: Double
    @ObservedObject var proStore: ProStore
    let onChoice: (ImportLimitChoice) -> Void
    @State private var showPaywall = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(ImportLimitPrompt.title(durationSeconds: durationSeconds))
                    .font(.system(.title2, design: .serif))
                    .fontWeight(.bold)
                Text(ImportLimitPrompt.body)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button {
                    Telemetry.shared.track(.softPromptTapped, ["kind": "import_limit"])
                    showPaywall = true
                } label: {
                    Text("Try Pro")
                        .font(.system(.headline, design: .serif))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.teal))
                }
                .accessibilityIdentifier("importLimit.tryPro")
                Text("Next you choose a plan. Nothing is charged today.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Button(ImportLimitPrompt.freeButtonTitle) {
                    Telemetry.shared.track(.softPromptDismissed, ["kind": "import_limit", "result": "free"])
                    onChoice(.writeFirstFree)
                }
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("importLimit.free")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Telemetry.shared.track(.softPromptDismissed, ["kind": "import_limit", "result": "cancel"])
                        onChoice(.cancel)
                    } label: {
                        Image(systemName: "xmark").font(.headline)
                    }
                    .accessibilityLabel("Cancel import")
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: proStore, trigger: PaywallTriggers.Trigger.importLimit.analyticsName)
            }
            .onChange(of: proStore.isPro) { _, isPro in
                if isPro { onChoice(.pro) }
            }
            .onAppear { Telemetry.shared.track(.softPromptShown, ["kind": "import_limit"]) }
        }
        .presentationDetents([.medium])
    }
}

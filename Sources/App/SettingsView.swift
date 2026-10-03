// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: ProStore
    @ObservedObject private var push = PushManager.shared
    @State private var shareUsage = Telemetry.shared.isEnabled
    @State private var pushBusy = false
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var restoring = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: { showPaywall = true }) {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundStyle(Ink.teal)
                            VStack(alignment: .leading) {
                                Text("Go Pro")
                                    .fontWeight(.semibold)
                                Text(store.isPro ? "You have Pro" : "Unlimited saves, MIDI, MusicXML & full PDF")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if store.isPro {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Ink.teal)
                            }
                        }
                    }
                    Button("Restore Purchases") {
                        restoring = true
                        Task {
                            await store.restore()
                            restoring = false
                        }
                    }
                    .disabled(restoring)
                }

                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { push.enabledInApp },
                        set: { on in
                            pushBusy = true
                            Task {
                                if on { await push.enable() } else { await push.disable() }
                                pushBusy = false
                            }
                        }))
                        .disabled(pushBusy)
                    Toggle("Share anonymous usage data", isOn: $shareUsage)
                        .onChange(of: shareUsage) { _, on in Telemetry.shared.isEnabled = on }
                } header: {
                    Text("Privacy")
                } footer: {
                    if push.status == .denied {
                        Text("Notifications are off for AI Music Radar in iOS Settings.")
                    } else {
                        Text("Usage data is anonymous: feature events only, never audio, notes or titles.")
                    }
                }

                Section("About") {
                    Link(destination: URL(string: "https://grepawk.com/music-radar/privacy")!) {
                        HStack {
                            Text("Privacy Policy")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://grepawk.com/music-radar/terms")!) {
                        HStack {
                            Text("Terms of Use")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(destination: URL(string: "https://grepawk.com/music-radar/support")!) {
                        HStack {
                            Text("Support")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPaywall) {
                PaywallView(store: store)
            }
        }
    }
}

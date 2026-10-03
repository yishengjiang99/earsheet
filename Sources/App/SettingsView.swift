// SPDX-License-Identifier: AGPL-3.0-or-later
import StoreKit
import SwiftUI

/// Settings: Pro status, Restore Purchases, notifications, analytics opt-out and the legal and
/// support links.
struct SettingsView: View {
    @ObservedObject private var store = ProStore.shared
    @ObservedObject private var push = PushManager.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var paywall: PaywallRequest?
    @State private var restoring = false
    @State private var message: String?
    @State private var analytics = Telemetry.isEnabled
    @State private var showManage = false

    var body: some View {
        NavigationStack {
            List {
                Section("AI Music Radar Pro") {
                    HStack {
                        Text("Plan")
                        Spacer()
                        Text(planText).foregroundStyle(.secondary)
                    }
                    if store.isPro {
                        if store.plan != .lifetime {
                            Button("Manage subscription") { showManage = true }
                        }
                    } else {
                        Button("Go Pro") {
                            paywall = PaywallRequest(trigger: .settings, onUnlocked: {})
                        }
                        .fontWeight(.semibold)
                    }
                    Button(restoring ? "Restoring…" : "Restore Purchases", action: restore)
                        .disabled(restoring)
                }

                Section {
                    Toggle("Notifications", isOn: Binding(
                        get: { push.isEnabled },
                        set: { on in Task { if on { await enablePush() } else { await push.disable() } } }
                    ))
                    Toggle("Share anonymous usage data", isOn: $analytics)
                        .onChange(of: analytics) { _, on in Telemetry.isEnabled = on }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Recordings never leave your iPhone. Usage data is anonymous app events (like \"page written\" or \"paywall shown\"), never audio, notes or titles.")
                }

                Section("About") {
                    link("Privacy Policy", AppConfig.Links.privacy)
                    link("Terms of Use", AppConfig.Links.terms)
                    link("Support", AppConfig.Links.support)
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("\(AppConfig.appVersion) (\(AppConfig.buildNumber))").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .manageSubscriptionsSheet(isPresented: $showManage, subscriptionGroupID: AppConfig.Product.subscriptionGroupID)
            .sheet(item: $paywall) { req in
                PaywallView(trigger: req.trigger, onUnlocked: req.onUnlocked)
            }
            .alert("AI Music Radar", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .task { await push.refresh() }
        }
    }

    private var planText: String {
        guard store.isPro else { return "Free" }
        guard let e = store.entitlement, let plan = store.plan else { return "Pro" }
        if plan == .lifetime { return "Lifetime" }
        let date = e.expiresAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
        let verb = e.willAutoRenew == false ? "ends" : "renews"
        return e.isTrial ? "\(plan.title) trial, \(verb) \(date)" : "\(plan.title), \(verb) \(date)"
    }

    private func link(_ title: String, _ url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            HStack {
                Text(title).foregroundStyle(Ink.ink)
                Spacer()
                Image(systemName: "arrow.up.right.square").foregroundStyle(.secondary)
            }
        }
    }

    private func enablePush() async {
        let ok = await push.requestPermission()
        if !ok, push.authorization == .denied {
            message = "Notifications are off for AI Music Radar. Turn them on in Settings › Notifications."
        }
    }

    private func restore() {
        restoring = true
        Task {
            let outcome = await store.restore()
            restoring = false
            switch outcome {
            case .restored: message = "Purchases restored. Pro is on."
            case .nothingFound: message = "No AI Music Radar purchases were found for this Apple ID."
            case .failed(let why): message = why
            }
        }
    }
}

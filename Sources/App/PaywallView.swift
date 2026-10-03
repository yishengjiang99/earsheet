// SPDX-License-Identifier: AGPL-3.0-or-later
import StoreKit
import SwiftUI

/// Full paywall (docs/paywall/PAYWALL_FLOW.md §3b): close button from the first frame, plan
/// picker (yearly preselected), trial timeline, Free vs Pro, privacy note, auto-renew disclosure,
/// sticky CTA, Restore · Terms · Privacy. Prices always come from StoreKit `displayPrice`.
struct PaywallView: View {
    var trigger: PaywallTrigger
    /// Runs after a verified purchase or a successful restore (resume the original action).
    var onUnlocked: () -> Void = {}

    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var selected: ProStore.Plan = .yearly
    @State private var message: String?
    @State private var unlocked: ProStore.PurchaseOutcome?
    @State private var restoring = false
    @State private var shownAt = Date()

    var body: some View {
        Group {
            if case .purchased(let id, let isTrial, let expires)? = unlocked {
                ProUnlockedView(productID: id, isTrial: isTrial, expiresAt: expires) {
                    onUnlocked()
                    dismiss()
                }
            } else {
                paywall
            }
        }
        .background(Ink.paper.ignoresSafeArea())
        .onAppear {
            shownAt = Date()
            PaywallGateStore.shared.recordView(trigger, screen: "paywall")
            if store.products.isEmpty { Task { await store.loadProducts() } }
        }
        .alert("AI Music Radar", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var paywall: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Ink.ink)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .padding(.horizontal, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("AI Music Radar Pro")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Ink.teal)
                        Text("Every note, in every format.")
                            .font(.system(size: 32, design: .serif))
                            .foregroundStyle(Ink.ink)
                        Text("Unlimited saves, full-length imports, and MIDI, MusicXML & full PDF export.")
                            .foregroundStyle(.secondary)
                    }

                    plans

                    if let days = trialDays {
                        TrialTimeline(days: days, priceLine: priceLine(selected))
                    }

                    FreeVsPro()

                    Text("Your music stays on your iPhone. Transcription runs on the device. No account, no upload, and it works offline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text("Payment is charged to your Apple ID when you confirm (for trials, when the trial ends). Subscriptions renew automatically at the same price and period unless canceled at least 24 hours before the end of the current period. Manage or cancel in Settings › Apple ID › Subscriptions. Lifetime is a one-time purchase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }

            footer
        }
    }

    // MARK: Plans

    @ViewBuilder private var plans: some View {
        switch store.loadState {
        case .unavailable(let why) where store.products.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                Text("Plans couldn't load from the App Store.")
                    .font(.headline)
                Text(why).font(.footnote).foregroundStyle(.secondary)
                Button("Try again") { Task { await store.loadProducts() } }
                    .foregroundStyle(Ink.teal)
            }
        default:
            if store.products.isEmpty {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 10) {
                    ForEach([ProStore.Plan.yearly, .monthly, .lifetime], id: \.self) { plan in
                        if let p = store.product(plan) {
                            PlanRow(plan: plan, product: p, trialDays: store.trialDays(for: p),
                                    monthlyPrice: store.product(.monthly)?.price,
                                    isSelected: plan == selected) {
                                selected = plan
                                Telemetry.shared.track(.paywallPlanSelect, ["product": p.id, "trigger": trigger.rawValue])
                            }
                        }
                    }
                }
            }
        }
    }

    private var trialDays: Int? {
        guard let p = store.product(selected) else { return nil }
        return store.trialDays(for: p)
    }

    private func priceLine(_ plan: ProStore.Plan) -> String {
        guard let p = store.product(plan) else { return "" }
        switch plan {
        case .monthly: return "\(p.displayPrice)/month"
        case .yearly: return "\(p.displayPrice)/year"
        case .lifetime: return "\(p.displayPrice) once"
        }
    }

    // MARK: Footer

    private var ctaTitle: String {
        guard let p = store.product(selected) else { return "Continue" }
        if selected == .lifetime { return "Buy Lifetime for \(p.displayPrice)" }
        if let d = store.trialDays(for: p) { return "Start \(d)-day free trial" }
        return "Subscribe for \(priceLine(selected))"
    }

    private var ctaFootnote: String {
        guard let p = store.product(selected) else { return "" }
        if selected == .lifetime { return "One payment, no renewal." }
        if let d = store.trialDays(for: p) {
            return "Free for \(d) days, then \(priceLine(selected)). Renews automatically. Cancel anytime in Settings."
        }
        return "\(priceLine(selected)). Renews automatically. Cancel anytime in Settings."
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: buy) {
                Group {
                    if store.purchasingProductID != nil {
                        ProgressView().tint(.white)
                    } else {
                        Text(ctaTitle).font(.headline)
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(Ink.teal, in: Capsule())
            }
            .disabled(store.product(selected) == nil || store.purchasingProductID != nil || restoring)

            Text(ctaFootnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 6) {
                Button(restoring ? "Restoring…" : "Restore Purchases", action: restore)
                    .disabled(restoring)
                Text("·").foregroundStyle(.secondary)
                Button("Terms") { openURL(AppConfig.Links.terms) }
                Text("·").foregroundStyle(.secondary)
                Button("Privacy") { openURL(AppConfig.Links.privacy) }
            }
            .font(.footnote)
            .foregroundStyle(Ink.teal)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Ink.paper.shadow(.drop(color: .black.opacity(0.06), radius: 8, y: -2)))
    }

    // MARK: Actions

    private func close() {
        PaywallGateStore.shared.recordDismiss(trigger, screen: "paywall", method: "close",
                                              seconds: Date().timeIntervalSince(shownAt))
        dismiss()
    }

    private func buy() {
        guard let p = store.product(selected) else { return }
        Task {
            let outcome = await store.purchase(p, trigger: trigger.rawValue)
            switch outcome {
            case .purchased: unlocked = outcome
            case .pending: message = "Your purchase is waiting for approval. Pro unlocks as soon as it's approved."
            case .failed(let why): message = why
            case .cancelled: break
            }
        }
    }

    private func restore() {
        restoring = true
        Task {
            let outcome = await store.restore()
            restoring = false
            switch outcome {
            case .restored:
                onUnlocked()
                message = "Purchases restored. Pro is on."
            case .nothingFound: message = "No AI Music Radar purchases were found for this Apple ID."
            case .failed(let why): message = why
            }
        }
    }
}

private struct PlanRow: View {
    var plan: ProStore.Plan
    var product: Product
    var trialDays: Int?
    var monthlyPrice: Decimal?
    var isSelected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Ink.teal : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(plan.title).font(.headline).foregroundStyle(Ink.ink)
                        if let badge { Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Ink.teal, in: Capsule()) }
                    }
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice).font(.headline).foregroundStyle(Ink.ink)
                    Text(period).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(isSelected ? 1 : 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Ink.teal : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var period: String {
        switch plan {
        case .monthly: "per month"
        case .yearly: "per year"
        case .lifetime: "once"
        }
    }

    private var badge: String? {
        guard plan == .yearly, let m = monthlyPrice, m > 0 else { return nil }
        let save = 1 - (product.price as NSDecimalNumber).doubleValue / ((m as NSDecimalNumber).doubleValue * 12)
        return save >= 0.1 ? "Save \(Int((save * 100).rounded()))%" : nil
    }

    private var detail: String {
        switch plan {
        case .lifetime: return "One payment, no renewal"
        case .yearly:
            let perMonth = (product.price / 12).formatted(product.priceFormatStyle)
            return trialDays.map { "≈ \(perMonth)/month · \($0) days free, cancel anytime" } ?? "≈ \(perMonth)/month"
        case .monthly:
            return trialDays.map { "Billed monthly · \($0) days free, cancel anytime" } ?? "Billed monthly"
        }
    }
}

private struct TrialTimeline: View {
    var days: Int
    var priceLine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            step("Today", "Every Pro export and unlimited saves unlock.")
            step("Day \(max(1, days - 2))", "We remind you the trial is ending, if you turn on the reminder.")
            step("Day \(days)", "\(priceLine) starts unless you cancel before.")
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Ink.teal.opacity(0.08)))
    }

    private func step(_ when: String, _ what: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(when).font(.subheadline.weight(.semibold)).frame(width: 64, alignment: .leading)
            Text(what).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct FreeVsPro: View {
    private let rows: [(String, String, String)] = [
        ("Listen live, see and play the score", "✓", "✓"),
        ("MP3 of the take, photo of the page", "✓", "✓"),
        ("Saved pieces", "\(AppConfig.Free.savedTakes)", "Unlimited"),
        ("Imported audio", "First \(Int(AppConfig.Free.importSeconds)) s", "Full length"),
        ("PDF export", "First \(Int(AppConfig.Free.pdfSeconds)) s", "Full length"),
        ("MIDI and MusicXML export", "–", "✓"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            row("", "Free", "Pro", header: true)
            ForEach(rows, id: \.0) { r in
                Divider()
                row(r.0, r.1, r.2, header: false)
            }
        }
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.7)))
    }

    private func row(_ a: String, _ b: String, _ c: String, header: Bool) -> some View {
        HStack {
            Text(a).frame(maxWidth: .infinity, alignment: .leading)
            Text(b).frame(width: 70)
            Text(c).frame(width: 80).foregroundStyle(header ? Ink.teal : Ink.ink)
        }
        .font(header ? .caption.weight(.semibold) : .footnote)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// Shown after a verified purchase (PAYWALL_FLOW §3c). The trial reminder is the moment we ask
/// for notification permission (never at first launch); it also registers for remote push.
struct ProUnlockedView: View {
    var productID: String
    var isTrial: Bool
    var expiresAt: Date?
    var onContinue: () -> Void
    @State private var reminderSet = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(Ink.teal)
            Text("You're in. Pro is on.")
                .font(.system(size: 30, design: .serif))
            VStack(alignment: .leading, spacing: 6) {
                Label("Unlimited saved pieces", systemImage: "checkmark")
                Label("Full-length imports and PDF", systemImage: "checkmark")
                Label("MIDI and MusicXML export", systemImage: "checkmark")
            }
            .font(.subheadline)
            if isTrial, let end = expiresAt {
                Text("Your free trial ends \(end.formatted(date: .abbreviated, time: .omitted)).")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onContinue) {
                Text("Continue")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Ink.teal, in: Capsule())
            }
            if isTrial, let end = expiresAt {
                Button(reminderSet ? "Reminder set" : "Turn on trial reminder") {
                    Task { reminderSet = await PushManager.shared.scheduleTrialReminder(trialEnds: end) }
                }
                .disabled(reminderSet)
                .foregroundStyle(Ink.teal)
            }
            Text("Cancel anytime in Settings › Apple ID › Subscriptions.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(28)
    }
}

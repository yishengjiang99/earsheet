// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import StoreKit

/// Full paywall: plan picker (yearly preselected), benefits, sticky CTA.
/// All prices come from Product.displayPrice (localized), never hard-coded.
struct PaywallView: View {
    @ObservedObject var store: ProStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String = ProStore.yearlyID
    @State private var isPurchasing = false
    @State private var showTrialStarted = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        planPicker
                        benefits
                        comparisonTable
                        legalLinks
                        Spacer(minLength: 100)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                }

                // Sticky CTA footer.
                VStack(spacing: 10) {
                    Button(action: buySelected) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Ink.teal)
                                .frame(height: 54)
                            if isPurchasing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(ctaTitle)
                                    .font(.system(.headline, design: .serif))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .disabled(isPurchasing || selectedProduct == nil)
                    .accessibilityLabel("Subscribe to \(selectedProduct?.displayName ?? "Pro")")

                    Button("Restore Purchases") {
                        Task { await store.restore() }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial)
            }
            .background(Ink.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(.headline)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .task {
                await store.loadProducts()
            }
            .alert("AI Music Radar", isPresented: Binding(
                get: { store.purchaseError != nil },
                set: { if !$0 { store.purchaseError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(store.purchaseError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AI Music Radar Pro")
                .font(.system(.largeTitle, design: .serif))
                .fontWeight(.bold)
            Text("Every note, in every format.")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(.secondary)
            Text("Unlimited saves, full-length imports, and MIDI, MusicXML & full PDF export.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var planPicker: some View {
        VStack(spacing: 10) {
            ForEach(store.products) { product in
                PlanRow(
                    product: product,
                    isSelected: product.id == selectedID,
                    badge: badge(for: product)
                ) {
                    selectedID = product.id
                }
            }
            if store.products.isEmpty {
                ProgressView("Loading prices…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
    }

    private func badge(for product: Product) -> String? {
        switch product.id {
        case ProStore.yearlyID: return "Save 50%"
        case ProStore.lifetimeID: return "Launch price"
        default: return nil
        }
    }

    private var selectedProduct: Product? {
        store.product(for: selectedID)
    }

    private var ctaTitle: String {
        guard let p = selectedProduct else { return "Continue" }
        if p.type == .nonConsumable {
            return "Buy for \(p.displayPrice)"
        }
        // Both subscriptions offer a 7-day free trial (introductory offer in ASC).
        return "Try 7 days free, then \(p.displayPrice)"
    }

    private func buySelected() {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        Task {
            let becamePro = await store.purchase(product)
            isPurchasing = false
            if becamePro {
                showTrialStarted = true
                dismiss()
            }
        }
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What Pro unlocks")
                .font(.system(.headline, design: .serif))
            BenefitRow(icon: "infinity", text: "Unlimited saved pieces")
            BenefitRow(icon: "waveform", text: "Full-length audio & video imports")
            BenefitRow(icon: "square.and.arrow.up", text: "MIDI, MusicXML & full PDF export")
        }
    }

    private var comparisonTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Free vs Pro")
                .font(.system(.headline, design: .serif))
            ComparisonRow(feature: "Live transcription", free: "Unlimited", pro: "Unlimited")
            ComparisonRow(feature: "Saved pieces", free: "3", pro: "Unlimited")
            ComparisonRow(feature: "Import length", free: "First 30 s", pro: "Full length")
            ComparisonRow(feature: "PDF export", free: "First 30 s", pro: "Full length")
            ComparisonRow(feature: "MIDI & MusicXML", free: "–", pro: "Included")
            ComparisonRow(feature: "MP3 & photo", free: "Included", pro: "Included")
        }
        .font(.subheadline)
    }

    private var legalLinks: some View {
        VStack(spacing: 8) {
            Link("Privacy Policy", destination: URL(string: "https://grepawk.com/music-radar/privacy")!)
            Link("Terms of Use", destination: URL(string: "https://grepawk.com/music-radar/terms")!)
            Text("Payment is charged to your Apple ID at confirmation. Subscriptions auto-renew unless cancelled at least 24 hours before the period ends.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }
}

// MARK: - Rows

private struct PlanRow: View {
    let product: Product
    let isSelected: Bool
    let badge: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .font(.headline)
                        if let badge {
                            Text(badge)
                                .font(.caption)
                                .fontWeight(.bold)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Ink.teal)
                                .foregroundStyle(.white)
                                .clipShape(Capsule())
                        }
                    }
                    Text(planSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(product.displayPrice)
                    .font(.headline)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Ink.teal : .secondary)
                    .font(.title3)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Ink.teal : Color.secondary.opacity(0.3), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(product.displayName), \(product.displayPrice)")
    }

    private var planSubtitle: String {
        switch product.id {
        case ProStore.yearlyID:
            return "≈ $2.50/month, billed yearly · 7 days free"
        case ProStore.monthlyID:
            return "Billed monthly · 7 days free, cancel anytime"
        case ProStore.lifetimeID:
            return "One payment, no renewal"
        default:
            return product.description
        }
    }
}

private struct BenefitRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Ink.teal)
                .frame(width: 24)
            Text(text)
                .font(.body)
        }
    }
}

private struct ComparisonRow: View {
    let feature: String
    let free: String
    let pro: String

    var body: some View {
        HStack {
            Text(feature)
            Spacer()
            Text(free)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(pro)
                .fontWeight(.semibold)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }
}

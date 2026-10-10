// SPDX-License-Identifier: AGPL-3.0-or-later
import SwiftUI
import StoreKit

/// Full paywall: plan picker (yearly preselected), benefits, sticky CTA.
/// All prices come from StoreKit (Product.displayPrice / price / priceFormatStyle), never hard-coded.
/// Trial copy appears only when the account is eligible for the product's free-trial intro offer.
/// Guideline 3.1.2: localized price + period, auto-renew terms, Restore, Terms (Apple standard EULA), Privacy.
struct PaywallView: View {
    @ObservedObject var store: ProStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedID: String = ProStore.yearlyID
    @State private var isPurchasing = false
    @State private var isRestoring = false

    static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacyURL = URL(string: "https://grepawk.com/music-radar/privacy")!

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
                    Button(action: ctaAction) {
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
                    .disabled(isPurchasing || isRestoring || store.isLoadingProducts)
                    .accessibilityLabel(ctaTitle)

                    Button(isRestoring ? "Restoring…" : "Restore Purchases") {
                        isRestoring = true
                        Task {
                            let restored = await store.restore()
                            isRestoring = false
                            if restored { dismiss() }
                        }
                    }
                    .disabled(isRestoring || isPurchasing)
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
                Telemetry.shared.track(.paywallView)
                await store.loadProducts()
                selectDefaultPlan()
            }
            .onChange(of: store.products.map(\.id)) { _, _ in selectDefaultPlan() }
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
                    badge: badge(for: product),
                    subtitle: subtitle(for: product),
                    periodText: product.subscription.map { "per " + PaywallPricing.Period($0.subscriptionPeriod).perText }
                ) {
                    selectedID = product.id
                }
            }
            if store.products.isEmpty {
                if store.isLoadingProducts || store.productsError == nil {
                    ProgressView("Loading prices…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(store.productsError ?? "Prices aren't available right now.")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { retryLoad() }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            }
        }
    }

    private var monthlyProduct: Product? { store.product(for: ProStore.monthlyID) }

    /// Formats a StoreKit Decimal amount in the product's own currency/locale.
    private func format(_ amount: Decimal, like product: Product) -> String {
        amount.formatted(product.priceFormatStyle)
    }

    /// "Save N%" for multi-month plans, computed from StoreKit prices against the monthly plan.
    private func badge(for product: Product) -> String? {
        guard let sub = product.subscription, let monthly = monthlyProduct, monthly.id != product.id,
              monthly.priceFormatStyle.currencyCode == product.priceFormatStyle.currencyCode,
              let pct = PaywallPricing.savingsPercent(price: product.price,
                                                      period: PaywallPricing.Period(sub.subscriptionPeriod),
                                                      monthlyPrice: monthly.price)
        else { return nil }
        return "Save \(pct)%"
    }

    private func subtitle(for product: Product) -> String {
        guard let sub = product.subscription else {
            return PaywallPricing.planSubtitle(isSubscription: false, period: nil, monthlyEquivalentText: nil, trial: nil)
        }
        let period = PaywallPricing.Period(sub.subscriptionPeriod)
        let perMonth = PaywallPricing.monthlyEquivalent(price: product.price, period: period).map { format($0, like: product) }
        return PaywallPricing.planSubtitle(isSubscription: true, period: period,
                                           monthlyEquivalentText: perMonth, trial: store.eligibleTrial(for: product))
    }

    private var selectedProduct: Product? {
        store.product(for: selectedID)
    }

    private var ctaTitle: String {
        guard let p = selectedProduct else {
            if store.isLoadingProducts { return "Loading prices…" }
            return store.products.isEmpty ? "Try Again" : "Choose a plan"
        }
        return PaywallPricing.ctaTitle(isSubscription: p.subscription != nil, displayPrice: p.displayPrice,
                                       period: p.subscription.map { PaywallPricing.Period($0.subscriptionPeriod) },
                                       trial: store.eligibleTrial(for: p))
    }

    private var disclosureText: String {
        guard let p = selectedProduct else {
            return "Pro is available as an auto-renewing yearly or monthly subscription, or a one-time Lifetime purchase. Subscriptions renew automatically unless cancelled at least 24 hours before the end of the current period."
        }
        return PaywallPricing.disclosure(isSubscription: p.subscription != nil, displayName: p.displayName,
                                         displayPrice: p.displayPrice,
                                         period: p.subscription.map { PaywallPricing.Period($0.subscriptionPeriod) },
                                         trial: store.eligibleTrial(for: p))
    }

    private func selectDefaultPlan() {
        if store.product(for: selectedID) == nil, let first = store.products.first {
            selectedID = first.id
        }
    }

    private func retryLoad() {
        Task {
            await store.loadProducts(force: true)
            selectDefaultPlan()
        }
    }

    /// CTA buys the selected plan; with no products loaded it retries instead of doing nothing.
    private func ctaAction() {
        if selectedProduct == nil {
            retryLoad()
        } else {
            buySelected()
        }
    }

    private func buySelected() {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        Task {
            let becamePro = await store.purchase(product)
            isPurchasing = false
            if becamePro {
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
        VStack(spacing: 10) {
            Text(disclosureText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link("Terms of Use (EULA)", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.footnote)
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
    let subtitle: String
    let periodText: String?
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
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(product.displayPrice)
                        .font(.headline)
                    if let periodText {
                        Text(periodText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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
        .accessibilityLabel("\(product.displayName), \(product.displayPrice) \(periodText ?? ""), \(subtitle)")
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

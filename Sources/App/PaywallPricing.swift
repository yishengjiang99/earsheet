// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation
import StoreKit

/// Pure paywall pricing/copy logic, kept free of SwiftUI and live StoreKit calls so it is unit-testable.
/// Every number comes from StoreKit (Product.price, Decimal) and is formatted with the product's own
/// priceFormatStyle, so currency, symbol and fraction digits follow the user's storefront.
enum PaywallPricing {
    /// A subscription or offer period, mirrored from Product.SubscriptionPeriod so tests can build one.
    struct Period: Equatable {
        enum Unit: Equatable { case day, week, month, year }
        var value: Int
        var unit: Unit

        init(value: Int, unit: Unit) {
            self.value = value
            self.unit = unit
        }

        init(_ period: Product.SubscriptionPeriod) {
            value = period.value
            switch period.unit {
            case .day: unit = .day
            case .week: unit = .week
            case .month: unit = .month
            case .year: unit = .year
            @unknown default: unit = .month
            }
        }

        /// Whole months in the period (nil for day/week periods, which have no meaningful monthly price).
        var months: Int? {
            switch unit {
            case .year: return value * 12
            case .month: return value
            case .day, .week: return nil
            }
        }

        /// "year", "month", "3 months", "week", "7 days".
        var text: String {
            let singular: String
            switch unit {
            case .day: singular = "day"
            case .week: singular = "week"
            case .month: singular = "month"
            case .year: singular = "year"
            }
            return value == 1 ? singular : "\(value) \(singular)s"
        }

        /// Free-trial wording: one week reads as "7 days", other periods as "1 month", "2 weeks", "3 days".
        var trialText: String {
            switch unit {
            case .week where value == 1: return "7 days"
            case .day: return value == 1 ? "1 day" : "\(value) days"
            default: return value == 1 ? "1 \(text)" : text
            }
        }

        /// Adjective form for "a 7-day free trial", "a 1-month free trial".
        var trialAdjective: String {
            switch unit {
            case .week: return "\(value * 7)-day"
            case .day: return "\(value)-day"
            case .month: return "\(value)-month"
            case .year: return "\(value)-year"
            }
        }

        /// Short form for "/period" suffixes: "year", "month", "3 months".
        var perText: String { text }
    }

    /// Introductory offer summary used for copy.
    struct Trial: Equatable {
        var period: Period
    }

    /// Free trial the user can actually get: only when StoreKit says the account is eligible
    /// (Product.SubscriptionInfo.isEligibleForIntroOffer) AND the product has a free-trial intro offer.
    static func eligibleTrial(isEligible: Bool, offerIsFreeTrial: Bool, offerPeriod: Period?) -> Trial? {
        guard isEligible, offerIsFreeTrial, let offerPeriod else { return nil }
        return Trial(period: offerPeriod)
    }

    /// price / months, e.g. 29.99 per year -> 2.4991666…; formatting rounds to the currency's digits.
    static func monthlyEquivalent(price: Decimal, period: Period) -> Decimal? {
        guard let months = period.months, months > 1 else { return nil }
        return price / Decimal(months)
    }

    /// Whole-percent saving of `price` over `period` versus paying `monthlyPrice` every month, rounded
    /// down so the claim is never overstated. nil when there is no real saving or the inputs don't compare.
    static func savingsPercent(price: Decimal, period: Period, monthlyPrice: Decimal) -> Int? {
        guard let months = period.months, months > 1, monthlyPrice > 0 else { return nil }
        let full = monthlyPrice * Decimal(months)
        guard full > price else { return nil }
        var ratio = (full - price) / full * 100
        var floored = Decimal()
        NSDecimalRound(&floored, &ratio, 0, .down)
        let pct = NSDecimalNumber(decimal: floored).intValue
        return pct >= 1 ? pct : nil
    }

    /// Sticky CTA title.
    static func ctaTitle(isSubscription: Bool, displayPrice: String, period: Period?, trial: Trial?) -> String {
        guard isSubscription, let period else { return "Buy for \(displayPrice)" }
        if let trial {
            return "Try \(trial.period.trialText) free, then \(displayPrice)/\(period.perText)"
        }
        return "Subscribe for \(displayPrice)/\(period.perText)"
    }

    /// Plan row subtitle.
    static func planSubtitle(isSubscription: Bool, period: Period?, monthlyEquivalentText: String?, trial: Trial?) -> String {
        guard isSubscription, let period else { return "One payment, no renewal" }
        var parts: [String] = []
        switch period.unit {
        case .year where period.value == 1:
            if let m = monthlyEquivalentText { parts.append("≈ \(m)/month, billed yearly") } else { parts.append("Billed yearly") }
        case .month where period.value == 1:
            parts.append("Billed monthly, cancel anytime")
        default:
            if let m = monthlyEquivalentText { parts.append("≈ \(m)/month, billed every \(period.text)") } else { parts.append("Billed every \(period.text)") }
        }
        if let trial { parts.append("\(trial.period.trialText) free") }
        return parts.joined(separator: " · ")
    }

    /// Guideline 3.1.2 disclosure for the selected product.
    static func disclosure(isSubscription: Bool, displayName: String, displayPrice: String, period: Period?, trial: Trial?) -> String {
        guard isSubscription, let period else {
            return "\(displayName) is a one-time purchase of \(displayPrice). It does not renew. Payment is charged to your Apple Account at confirmation of purchase."
        }
        var s = "\(displayName): \(displayPrice) per \(period.perText)"
        if let trial {
            s += " after a \(trial.period.trialAdjective) free trial"
        }
        s += ". Payment is charged to your Apple Account"
        s += trial == nil ? " at confirmation of purchase." : " when the free trial ends."
        s += " The subscription renews automatically unless it is cancelled at least 24 hours before the end of the current period; your account is charged for renewal within 24 hours before the period ends. Manage or cancel any time in your App Store account settings."
        return s
    }
}

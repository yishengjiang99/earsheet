// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// What the current Pro entitlement is: plan, trial and end/renewal date, taken from the verified
/// `Transaction`. Pure value so the copy built from it is unit-testable.
struct ProStatus: Equatable {
    enum Plan: Equatable {
        case monthly, yearly, lifetime
    }

    var plan: Plan
    /// Renewal, trial-end or expiry date; nil for Lifetime.
    var expiresAt: Date?
    /// The current period is the introductory free trial.
    var isTrial: Bool
    /// From the subscription's renewal info; nil until known.
    var willRenew: Bool?

    @MainActor
    static func plan(forProductID id: String) -> Plan? {
        switch id {
        case ProStore.monthlyID: return .monthly
        case ProStore.yearlyID: return .yearly
        case ProStore.lifetimeID: return .lifetime
        default: return nil
        }
    }

    /// The entitlement to describe when several are current: Lifetime wins, else the latest end date.
    static func best(_ candidates: [ProStatus]) -> ProStatus? {
        if let lifetime = candidates.first(where: { $0.plan == .lifetime }) { return lifetime }
        return candidates.max { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }
    }

    var planName: String {
        switch plan {
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .lifetime: return "Lifetime"
        }
    }

    /// "Nov 17": short, in the user's language and time zone.
    static func formatDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// One line right after a purchase: "Pro is on. Trial ends Oct 24."
    func confirmation(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard plan != .lifetime else { return "Pro is on. Lifetime, thank you." }
        guard let expiresAt else { return "Pro is on." }
        let date = Self.formatDate(expiresAt, locale: locale, timeZone: timeZone)
        if isTrial { return "Pro is on. Trial ends \(date)." }
        return willRenew == false ? "Pro is on until \(date)." : "Pro is on. Renews \(date)."
    }
}

/// A Pro-only export the user tapped before the paywall: done once when Pro turns on.
struct ExportResume: Equatable {
    private(set) var pending: ExportFormat?

    /// The paywall opened from a locked row.
    mutating func request(_ format: ExportFormat) { pending = format }

    /// The paywall closed without a purchase: forget the action.
    mutating func cancel() { pending = nil }

    /// Pro just turned on. Returns the export to run, exactly once.
    mutating func proChanged(wasPro: Bool, isPro: Bool) -> ExportFormat? {
        guard !wasPro, isPro, let format = pending else { return nil }
        pending = nil
        return format
    }
}

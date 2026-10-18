// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// The two Pro-only export formats.
enum ExportFormat: String, Equatable {
    case midi
    case musicXML

    /// Anonymous `source` value on events.
    var analyticsName: String {
        switch self {
        case .midi: return "export_midi"
        case .musicXML: return "export_musicxml"
        }
    }
}

/// When the soft "Export this as MIDI & MusicXML" sheet appears (PAYWALL_FLOW screen 1).
///
/// - `firstShare`: the first time the export sheet opens on the user's first finished take. An
///   automatic, capped prompt (policy trigger `.firstExport`, shown once ever).
/// - `lockedRow`: the user tapped MIDI or MusicXML. A tap, so it always opens and never counts
///   toward the caps or the dismissal total.
@MainActor
enum ExportInterstitialFlow {
    enum Entry: Equatable, Identifiable {
        case firstShare
        case lockedRow(ExportFormat)

        var id: String {
            switch self {
            case .firstShare: return "firstShare"
            case .lockedRow(let format): return "lockedRow.\(format.rawValue)"
            }
        }

        var trigger: PaywallTriggers.Trigger {
            switch self {
            case .firstShare: return .firstExport
            case .lockedRow: return .exportLockedRow
            }
        }

        /// The format a locked-row tap asked for.
        var format: ExportFormat? {
            if case .lockedRow(let format) = self { return format }
            return nil
        }
    }

    /// The entry to present when the export sheet opens, or nil. Samples never count as a finished take.
    /// Records the automatic presentation when it returns an entry.
    static func entryOnOpen(isSample: Bool, isPro: Bool, purchaseActive: Bool, isRecording: Bool = false,
                            triggers: PaywallTriggers?) -> Entry? {
        guard !isSample, let triggers else { return nil }
        let context = UpgradePromptContext(isPro: isPro, finishedTakes: 1, isRecording: isRecording,
                                           purchaseActive: purchaseActive)
        guard triggers.decision(.firstExport, context: context).isShow else { return nil }
        triggers.recordAutoShown(.firstExport)
        return .firstShare
    }

    /// The entry for a tap on a locked row. Never recorded. Without a policy (previews) it still opens.
    static func entryForLockedRow(_ format: ExportFormat, isPro: Bool, purchaseActive: Bool,
                                  triggers: PaywallTriggers?) -> Entry? {
        guard let triggers else { return isPro ? nil : .lockedRow(format) }
        let context = UpgradePromptContext(isPro: isPro, finishedTakes: 1, purchaseActive: purchaseActive)
        return triggers.decision(.exportLockedRow, userInitiated: true, context: context).isShow
            ? .lockedRow(format) : nil
    }

    /// The sheet closed. Only an automatic presentation that was not taken up counts as a dismissal.
    static func closed(_ entry: Entry, tookPlans: Bool, isPro: Bool, triggers: PaywallTriggers?) {
        guard entry == .firstShare, !tookPlans, !isPro else { return }
        triggers?.recordDismiss()
    }

    // MARK: - Copy

    static let headline = "Export this as MIDI & MusicXML"
    static let freePDFTitle = "Share free PDF (first 30 s)"

    /// "Try Pro free for 7 days" only when the account can actually get the trial; else "See Pro plans".
    static func primaryTitle(trialText: String?) -> String {
        trialText.map { "Try Pro free for \($0)" } ?? "See Pro plans"
    }

    static func body(title: String, trialText: String?) -> String {
        let tail = trialText.map { "Pro includes it, and the first \($0) are free." } ?? "Pro includes it."
        return "Open \(title) in GarageBand, Logic, MuseScore or Sibelius, every note, full length. \(tail)"
    }

    static let footnote = "Next you choose a plan. Nothing is charged today."
}

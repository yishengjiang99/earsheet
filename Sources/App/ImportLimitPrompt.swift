// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// What the user picked on the import-limit sheet.
enum ImportLimitChoice: Equatable {
    /// "Write the first 30 s free": continue as a free import.
    case writeFirstFree
    /// Pro turned on while the sheet was open: continue with the Pro length.
    case pro
    /// Closed without choosing: nothing is transcribed.
    case cancel
}

/// When to ask before transcribing a long import (design screen 7, rank-2 trigger).
@MainActor
enum ImportLimitPrompt {
    enum Decision: Equatable {
        /// Straight to transcription.
        case proceed
        /// Free user, file longer than the free length: offer the choice first.
        case prompt
    }

    static func decision(durationSeconds: Double, isPro: Bool) -> Decision {
        !isPro && durationSeconds > ImportPolicy.freeSeconds ? .prompt : .proceed
    }

    /// "0:48"
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func title(durationSeconds: Double) -> String {
        "This file is \(clock(durationSeconds)) long"
    }

    static var body: String {
        "Free imports write the first \(Int(ImportPolicy.freeSeconds)) s of a file. "
            + "Pro writes up to \(Int(ImportPolicy.proSeconds)) s."
    }

    static var freeButtonTitle: String { "Write the first \(Int(ImportPolicy.freeSeconds)) s free" }
}

/// Lets an import task wait for the sheet: `ask` suspends until the user chooses, closes the sheet
/// or the task is cancelled (a newer import).
@MainActor
final class ImportLimitGate: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let durationSeconds: Double
    }

    @Published var request: Request?
    private var continuation: CheckedContinuation<ImportLimitChoice, Never>?

    func ask(durationSeconds: Double) async -> ImportLimitChoice {
        resolve(.cancel)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<ImportLimitChoice, Never>) in
                continuation = cont
                request = Request(durationSeconds: durationSeconds)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(.cancel) }
        }
    }

    func resolve(_ choice: ImportLimitChoice) {
        request = nil
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: choice)
    }
}

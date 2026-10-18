// SPDX-License-Identifier: AGPL-3.0-or-later
import XCTest
@testable import EarSheet

@MainActor
private final class DeadlineBox { var done = false }

/// Runs `operation` but gives up after `seconds`, returning nil. The operation is not cancellable
/// (StoreKit purchase ignores cancellation), so it is abandoned rather than awaited.
@MainActor
func withDeadline<T: Sendable>(_ seconds: Double, _ operation: @escaping @MainActor () async -> T) async -> T? {
    let box = DeadlineBox()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        Task { @MainActor in
            let value = await operation()
            if !box.done { box.done = true; cont.resume(returning: value) }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if !box.done { box.done = true; cont.resume(returning: nil) }
        }
    }
}

extension ProStore {
    /// `purchase` with a deadline; skips (issue #86: StoreKit purchase hangs in the CI simulator) instead of hanging.
    func purchaseOrSkip(_ product: Product, seconds: Double = 30) async throws -> Bool {
        guard let result = await withDeadline(seconds, { await self.purchase(product) }) else {
            throw XCTSkip("StoreKit purchase did not complete within \(Int(seconds)) s in this environment (issue #86)")
        }
        return result
    }
}

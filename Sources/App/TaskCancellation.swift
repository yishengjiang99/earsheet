// SPDX-License-Identifier: AGPL-3.0-or-later
import Foundation

/// Runs `work` on a detached task at the given priority, but propagates
/// cancellation from the calling task (which `Task.detached` alone does not).
///
/// Use for CPU-bound work that must leave the main actor (model inference,
/// audio decoding) while still respecting cancellation when the user moves on.
func runCancellableDetached<T: Sendable>(
    priority: TaskPriority = .userInitiated,
    _ work: @Sendable @escaping () async throws -> T
) async throws -> T {
    let task = Task.detached(priority: priority, operation: work)
    return try await withTaskCancellationHandler {
        try await task.value
    } onCancel: {
        task.cancel()
    }
}

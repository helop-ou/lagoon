import Foundation

/// Ordered group requests. Every task is retained so cancel reaches the whole
/// chain; cancelling the tail does not propagate to earlier Tasks.
@MainActor
final class SyncPlayRequestQueue {
    private var tail: Task<Void, Never>?
    private var pending: [Int: Task<Void, Never>] = [:]
    private var nextID = 0

    @discardableResult
    func enqueue(
        _ work: @escaping @MainActor () async throws -> Void,
        retryDelay: Duration? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> Task<Void, Never> {
        let previous = tail
        nextID &+= 1
        let id = nextID
        let task = Task { [weak self] in
            defer { self?.pending[id] = nil }
            await previous?.value
            // Awaiting another task's value ignores cancellation.
            guard !Task.isCancelled else { return }
            do {
                do {
                    try await work()
                } catch {
                    try Task.checkCancellation()
                    // Only idempotent readiness retries; a repeated seek or
                    // next could move the group twice.
                    guard let retryDelay, !(error is CancellationError) else { throw error }
                    try await Task.sleep(for: retryDelay)
                    try Task.checkCancellation()
                    try await work()
                }
            } catch {
                // Release the next request; never move the local player.
                if !Task.isCancelled, !(error is CancellationError) { onFailure?() }
            }
        }
        pending[id] = task
        tail = task
        return task
    }

    func cancel() {
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        tail = nil
    }
}

import Foundation

/// Ordered group requests owned by one playback attachment. Every task is
/// retained so detaching cancels the in-flight request and all its followers;
/// cancelling only the tail of a chain does not propagate to earlier Tasks.
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
            // Awaiting another task's value does not observe cancellation.
            // Without this guard cancelled commands still reach the server.
            guard !Task.isCancelled else { return }
            do {
                do {
                    try await work()
                } catch {
                    try Task.checkCancellation()
                    // Readiness is idempotent and may retry once after a
                    // transient failure. Viewer transport never opts in:
                    // repeating a seek/next request could move the group twice.
                    guard let retryDelay, !(error is CancellationError) else { throw error }
                    try await Task.sleep(for: retryDelay)
                    try Task.checkCancellation()
                    try await work()
                }
            } catch {
                // The server remains authoritative. Failure must release
                // the next request, never move the local player on its own.
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

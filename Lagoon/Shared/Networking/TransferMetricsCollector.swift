import Foundation
import os

/// Keeps one task's transfer time: first response byte to last.
nonisolated final class TransferMetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var seconds: TimeInterval?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var transferSeconds: TimeInterval? {
        state.withLock { $0.seconds }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last,
              let start = transaction.responseStartDate,
              let end = transaction.responseEndDate else { return }
        let elapsed = end.timeIntervalSince(start)
        guard elapsed.isFinite, elapsed > 0 else { return }
        state.withLock { $0.seconds = elapsed }
    }
}

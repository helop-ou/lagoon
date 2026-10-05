import Foundation

/// Keeps one task's transfer time: first response byte to last.
nonisolated final class TransferMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: TimeInterval?

    var transferSeconds: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last,
              let start = transaction.responseStartDate,
              let end = transaction.responseEndDate else { return }
        let elapsed = end.timeIntervalSince(start)
        guard elapsed.isFinite, elapsed > 0 else { return }
        lock.lock()
        seconds = elapsed
        lock.unlock()
    }
}

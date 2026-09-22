import Foundation
import LagoonEngine

/// The bounded, retrying part of the transport, as pure rules: how many
/// envelopes may wait on disk, how a response is classified, and how long
/// to stay quiet after a failure or a rate limit. `SentryTransport` applies
/// them; the tests pin them.
nonisolated struct SentryTransportPolicy: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// Taken. Sentry may still ask for a pause on a 200 through
        /// `X-Sentry-Rate-Limits`; honour it before the next envelope.
        case accepted(pauseFor: TimeInterval?)
        /// The server said when to come back (429).
        case retryAfter(TimeInterval)
        /// The server will never take this envelope; drop it and move on.
        case discard
        /// Transient: keep the envelope, back off.
        case backoff
    }

    var maximumPending = 20
    var maximumEnvelopeBytes = 256 * 1024
    var initialBackoff: TimeInterval = 30
    var maximumBackoff: TimeInterval = 3_600
    var defaultRetryAfter: TimeInterval = 60

    static let standard = SentryTransportPolicy()

    func outcome(status: Int, headers: [String: String]) -> Outcome {
        switch status {
        case 200...299:
            return .accepted(pauseFor: rateLimit(headers: headers))
        case 429:
            return .retryAfter(retryDelay(headers: headers))
        case 408, 425:
            return .backoff
        case 400...499:
            // 400 invalid envelope, 413 too large, 401/403 wrong key: a
            // retry sends the same bytes to the same verdict.
            return .discard
        default:
            return .backoff
        }
    }

    /// The longest `X-Sentry-Rate-Limits` entry
    /// (`<seconds>:<categories>:<scope>,…`) that covers error events or
    /// attachments, on any status code. Nil when the header is absent or
    /// names only other categories. Header names match case-insensitively.
    func rateLimit(headers: [String: String]) -> TimeInterval? {
        guard let limits = header("X-Sentry-Rate-Limits", in: headers) else { return nil }
        var longest: TimeInterval = 0
        for entry in limits.split(separator: ",") {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard let first = parts.first,
                  let seconds = TimeInterval(first.trimmingCharacters(in: .whitespaces)), seconds > 0 else { continue }
            let categories = parts.count > 1
                ? parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                : []
            if categories.isEmpty || categories.contains("error") || categories.contains("default") || categories.contains("attachment") {
                longest = max(longest, seconds)
            }
        }
        return longest > 0 ? longest : nil
    }

    /// For a 429: the rate-limit header, else `Retry-After`, else the
    /// default.
    func retryDelay(headers: [String: String]) -> TimeInterval {
        if let limit = rateLimit(headers: headers) { return limit }
        if let retryAfter = header("Retry-After", in: headers), let seconds = TimeInterval(retryAfter.trimmingCharacters(in: .whitespaces)) {
            return max(seconds, 1)
        }
        return defaultRetryAfter
    }

    /// Exponential from `initialBackoff`, capped. Failure one waits the
    /// initial delay.
    func backoff(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = min(failures - 1, 12)
        return min(initialBackoff * pow(2, Double(exponent)), maximumBackoff)
    }

    private func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

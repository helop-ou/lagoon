import Foundation
import LagoonEngine
import os

/// Posts envelopes to a Sentry project over URLSession, from a bounded
/// on-disk queue, on its own utility queue. Nothing here runs on a playback
/// path: `submit` returns after enqueuing a block. The queue survives a
/// process exit; a purge of Caches loses pending reports, which is
/// acceptable for diagnostics.
nonisolated final class SentryTransport: DiagnosticSink, Sendable {
    private static let log = Logger(subsystem: "ee.helop.lagoon", category: "diagnostics")

    private let dsn: SentryDSN
    private let context: DiagnosticContext
    private let policy: SentryTransportPolicy
    private let directory: URL
    private let session: URLSession
    /// The tester's switch, consulted before every upload and every
    /// enqueue: turning reporting off also discards what is still queued,
    /// so nothing recorded before the change leaves the device after it.
    private let isEnabled: @Sendable () -> Bool
    private let queue = DispatchQueue(label: "ee.helop.lagoon.diagnostics", qos: .utility)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var notBefore: TimeInterval = 0
        var consecutiveFailures = 0
        var inFlight = false
        var retryScheduled = false
    }

    init(
        dsn: SentryDSN,
        context: DiagnosticContext,
        directory: URL? = nil,
        policy: SentryTransportPolicy = .standard,
        session: URLSession? = nil,
        isEnabled: @escaping @Sendable () -> Bool = { DiagnosticsPreference.isReportingEnabled }
    ) {
        self.dsn = dsn
        self.context = context
        self.policy = policy
        self.isEnabled = isEnabled
        self.directory = directory ?? Self.defaultDirectory
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 20
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    static var defaultDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "Diagnostics/pending", directoryHint: .isDirectory)
    }

    // MARK: - DiagnosticSink

    func submit(_ incident: DiagnosticIncident) {
        queue.async { [self] in
            guard isEnabled() else { return }
            guard let envelope = SentryEnvelope.make(incident: incident, context: context, dsn: dsn) else { return }
            guard envelope.data.count <= policy.maximumEnvelopeBytes else {
                Self.log.error("envelope too large: \(envelope.data.count, privacy: .public) bytes")
                return
            }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = String(format: "%013.0f-%@.envelope", incident.timestamp.timeIntervalSince1970 * 1_000, envelope.eventID)
                try envelope.data.write(to: directory.appending(path: name), options: .atomic)
            } catch {
                Self.log.error("could not queue envelope: \(error.localizedDescription, privacy: .public)")
                return
            }
            trimPending()
            drain()
        }
    }

    func flush() {
        queue.async { [self] in drain() }
    }

    // MARK: - Queue

    /// Oldest first, by the millisecond prefix in the file name.
    private func pendingFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { $0.pathExtension == "envelope" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Reporting was turned off: whatever is still waiting stays on this
    /// device. Runs on `queue`.
    private func discardPending() {
        for file in pendingFiles() {
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func trimPending() {
        let files = pendingFiles()
        guard files.count > policy.maximumPending else { return }
        for file in files.prefix(files.count - policy.maximumPending) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Sends one envelope at a time until the queue is empty, a limit
    /// applies, or a failure starts a backoff. Runs on `queue`.
    private func drain() {
        guard isEnabled() else {
            discardPending()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let shouldSend: Bool = state.withLock { state in
            guard !state.inFlight else { return false }
            if now < state.notBefore {
                scheduleRetry(after: state.notBefore - now, state: &state)
                return false
            }
            return true
        }
        guard shouldSend, let file = pendingFiles().first,
              let data = try? Data(contentsOf: file),
              let url = dsn.envelopeURL else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/x-sentry-envelope", forHTTPHeaderField: "Content-Type")
        request.setValue(dsn.authorizationHeader, forHTTPHeaderField: "X-Sentry-Auth")
        request.setValue("\(SentryEnvelope.sdkName)/\(SentryEnvelope.sdkVersion)", forHTTPHeaderField: "User-Agent")
        state.withLock { $0.inFlight = true }
        let task = session.dataTask(with: request) { [self] _, response, error in
            queue.async { [self] in
                complete(file: file, response: response as? HTTPURLResponse, error: error)
            }
        }
        task.resume()
    }

    private func complete(file: URL, response: HTTPURLResponse?, error: Error?) {
        let outcome: SentryTransportPolicy.Outcome
        if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            outcome = policy.outcome(status: response.statusCode, headers: headers)
        } else {
            outcome = .backoff
        }
        let now = ProcessInfo.processInfo.systemUptime
        // The lock's closure is `Sendable`, so the decision to keep draining
        // is its return value rather than a captured variable.
        let continueDraining: Bool = state.withLock { state in
            state.inFlight = false
            switch outcome {
            case .accepted(let pause):
                state.consecutiveFailures = 0
                try? FileManager.default.removeItem(at: file)
                if let pause {
                    state.notBefore = now + pause
                    scheduleRetry(after: pause, state: &state)
                    return false
                }
                return true
            case .discard:
                state.consecutiveFailures = 0
                try? FileManager.default.removeItem(at: file)
                Self.log.error("envelope rejected with status \(response?.statusCode ?? 0, privacy: .public)")
                return true
            case .retryAfter(let delay):
                state.notBefore = now + delay
                scheduleRetry(after: delay, state: &state)
                return false
            case .backoff:
                state.consecutiveFailures += 1
                let delay = policy.backoff(afterConsecutiveFailures: state.consecutiveFailures)
                state.notBefore = now + delay
                scheduleRetry(after: delay, state: &state)
                return false
            }
        }
        if continueDraining {
            drain()
        }
    }

    /// One timer at a time; a scheduled retry that fires early simply finds
    /// `notBefore` still ahead and reschedules.
    private func scheduleRetry(after delay: TimeInterval, state: inout State) {
        guard !state.retryScheduled else { return }
        state.retryScheduled = true
        queue.asyncAfter(deadline: .now() + max(delay, 1)) { [self] in
            self.state.withLock { $0.retryScheduled = false }
            drain()
        }
    }
}

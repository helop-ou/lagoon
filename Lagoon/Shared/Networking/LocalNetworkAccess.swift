import Foundation
#if os(iOS)
import Network
#endif

/// Diagnoses the endpoint the viewer tried. Only Network's explicit path
/// reason proves local-network denial; timeouts and DNS failures do not.
nonisolated enum LocalNetworkAccess {
    enum Failure: LocalizedError {
        case denied

        var errorDescription: String? {
            "Allow Local Network access for Lagoon in Settings, then try connecting again."
        }
    }

    static func explain(
        _ error: any Error,
        at url: URL,
        probe: @Sendable (URL) async -> Bool = isDenied
    ) async -> any Error {
        guard !Task.isCancelled, let error = error as? URLError,
              [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
               .dnsLookupFailed, .networkConnectionLost, .timedOut].contains(error.code) else { return error }
        if await probe(url), !Task.isCancelled { return Failure.denied }
        return error
    }

    static func isDenied(at url: URL) async -> Bool {
        #if os(iOS)
        guard !Task.isCancelled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(percentEncoded: false), !host.isEmpty,
              let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? (url.scheme == "https" ? 443 : 80)) ?? 0),
              port.rawValue != 0 else { return false }
        #if DEBUG
        // The simulator has no local-network prompt. The UI fixture may fake
        // this diagnosis for its loopback origin only, after a real failure.
        // It cannot grant access or affect a Release build.
        if host == "127.0.0.1",
           ProcessInfo.processInfo.environment["LAGOON_TEST_DENIED_ORIGIN"] == url.absoluteString {
            return true
        }
        #endif
        let hostname = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let connection = NWConnection(host: NWEndpoint.Host(hostname), port: port, using: .tcp)
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .waiting:
                continuation.yield(connection.currentPath?.unsatisfiedReason == .localNetworkDenied)
                continuation.finish()
            case .ready, .failed, .cancelled:
                continuation.yield(false)
                continuation.finish()
            default: break
            }
        }
        continuation.onTermination = { _ in connection.cancel() }
        connection.start(queue: DispatchQueue(label: "ee.helop.lagoon.local-network-check"))
        defer {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await denied in stream { return denied }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #else
        return false
        #endif
    }
}

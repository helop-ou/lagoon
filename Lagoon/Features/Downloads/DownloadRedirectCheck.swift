import Foundation
import LagoonEngine

/// A background session follows redirects without asking its delegate, so it
/// cannot drop a proxy's headers when one leaves the server. Before a transfer
/// carries them, a foreground HEAD request that follows nothing asks where the
/// URL leads, and a redirect off the host or off HTTPS refuses the transfer.
///
/// Not iOS-only like the rest of Downloads, so the unit suite covers it.
nonisolated enum DownloadRedirectCheck {
    enum Outcome: Equatable {
        /// No redirect, or only ones that stay on the host over HTTPS.
        case staysOnServer
        case leavesServer
        case unreachable
    }

    /// Only a request carrying a proxy's headers has anything to leak.
    static func isNeeded(for authorization: MediaRequestAuthorization) -> Bool {
        !authorization.additionalHeaders.isEmpty
    }

    enum Step: Equatable {
        case done(Outcome)
        /// A redirect that stays on the host over HTTPS; see where it leads.
        case follow(URL)
    }

    private static let redirectStatuses: Set<Int> = [301, 302, 303, 307, 308]
    private static let maximumHops = 5

    /// What one response to a request for `url` means.
    static func step(from url: URL, status: Int, location: String?) -> Step {
        guard redirectStatuses.contains(status) else { return .done(.staysOnServer) }
        guard let target = location.flatMap({ URL(string: $0, relativeTo: url)?.absoluteURL }),
              target.host()?.lowercased() == url.host()?.lowercased(),
              ServerHeaderStore.isSecure(target) else { return .done(.leavesServer) }
        return .follow(target)
    }

    static func check(_ request: URLRequest, session: URLSession = probeSession) async -> Outcome {
        var probe = request
        probe.httpMethod = "HEAD"
        for _ in 0..<maximumHops {
            guard let url = probe.url,
                  let (_, response) = try? await session.data(for: probe, delegate: RefuseRedirects.shared),
                  let http = response as? HTTPURLResponse else { return .unreachable }
            switch step(from: url, status: http.statusCode, location: http.value(forHTTPHeaderField: "Location")) {
            case .done(let outcome): return outcome
            case .follow(let target): probe.url = target
            }
        }
        return .leavesServer
    }

    static let probeSession = UncachedSession.make(
        waitsForConnectivity: false, timeoutIntervalForRequest: 15, timeoutIntervalForResource: 15
    )

    /// Hands back each redirect response instead of following it.
    private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = RefuseRedirects()

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}

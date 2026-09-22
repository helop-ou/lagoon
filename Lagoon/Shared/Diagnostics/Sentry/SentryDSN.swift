import Foundation
import LagoonEngine

/// A parsed Sentry DSN: `scheme://publicKey@host[:port][/path]/projectID`.
/// The public key is a client key, not a secret; it only lets a client
/// submit events to that one project.
nonisolated struct SentryDSN: Equatable, Sendable {
    let scheme: String
    let publicKey: String
    let host: String
    let port: Int?
    /// Path in front of `/api/...`, without trailing slash. Empty for
    /// hosted Sentry.
    let basePath: String
    let projectID: String

    init?(string: String) {
        guard let components = URLComponents(string: string),
              let scheme = components.scheme, scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty,
              let user = components.user, !user.isEmpty else { return nil }
        var segments = components.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let project = segments.popLast(), !project.isEmpty,
              project.allSatisfy(\.isNumber) else { return nil }
        self.scheme = scheme
        publicKey = user
        self.host = host
        port = components.port
        basePath = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        projectID = project
    }

    var envelopeURL: URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = "\(basePath)/api/\(projectID)/envelope/"
        return components.url
    }

    /// `X-Sentry-Auth`. Version 7 is the current protocol; the client name
    /// is what the dashboard shows as the SDK.
    var authorizationHeader: String {
        "Sentry sentry_version=7, sentry_client=\(SentryEnvelope.sdkName)/\(SentryEnvelope.sdkVersion), sentry_key=\(publicKey)"
    }
}

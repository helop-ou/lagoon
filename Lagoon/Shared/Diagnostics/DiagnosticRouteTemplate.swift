import Foundation

/// Turns a request path into the shape a report may carry: letters-only
/// segments and API version segments survive, everything else becomes
/// `{id}`. `Users/8f3a…/Items/12c4…/PlaybackInfo` reports as
/// `Users/{id}/Items/{id}/PlaybackInfo`; a reverse-proxy base path is
/// removed first so the same route on two servers groups together.
nonisolated enum DiagnosticRouteTemplate {
    static let maximumSegments = 8

    /// A version segment such as `v1`: a lowercase `v` followed by digits and
    /// nothing else. Kept verbatim because Seerr mounts every route under
    /// `api/v1`, so blanking it reported all of them as `api/{id}/…` and made
    /// one Seerr route indistinguishable from another on the dashboard
    /// (HEL-180).
    ///
    /// Deliberately the narrowest exception that fixes that. A numeric id, a
    /// UUID, a slug and a filename all still become `{id}`, because the rule
    /// this file exists to keep is that nothing identifying the viewer or
    /// what they are watching leaves it.
    static func isVersionSegment(_ segment: some StringProtocol) -> Bool {
        guard segment.count >= 2, segment.first == "v" else { return false }
        return segment.dropFirst().utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    static func template(path: String, basePath: String? = nil) -> String {
        var remaining = Substring(path)
        if let basePath {
            let trimmedBase = basePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmedBase.isEmpty {
                let trimmedPath = remaining.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if trimmedPath.hasPrefix(trimmedBase) {
                    remaining = Substring(trimmedPath.dropFirst(trimmedBase.count))
                }
            }
        }
        let segments = remaining
            .split(separator: "/", omittingEmptySubsequences: true)
            .prefix(maximumSegments)
            .map { segment -> String in
                let isLetters = !segment.isEmpty && segment.utf8.allSatisfy { byte in
                    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                        || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                }
                return isLetters || isVersionSegment(segment) ? String(segment) : "{id}"
            }
        return segments.isEmpty ? "{id}" : segments.joined(separator: "/")
    }

    static func template(url: URL, serverURL: URL?) -> String {
        template(path: url.path, basePath: serverURL?.path)
    }
}

/// Which request failures are worth a report. An unreachable server, a lost
/// connection, and a cancelled task are the network being the network; the
/// app did nothing wrong and a tester cannot act on it. A TLS failure, a
/// malformed URL, or a response the app rejected is different.
nonisolated enum DiagnosticNetworkClassifier {
    static func isExpectedTransportFailure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cancelled, .notConnectedToInternet, .networkConnectionLost, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed, .callIsActive, .userCancelledAuthentication:
            return true
        default:
            return false
        }
    }

    /// Status codes that describe the account or the request as the server
    /// sees it rather than a fault: unauthorised, forbidden (the subtitle
    /// permission), and 304.
    static func isExpectedStatus(_ status: Int) -> Bool {
        status == 401 || status == 403 || status == 304
    }
}

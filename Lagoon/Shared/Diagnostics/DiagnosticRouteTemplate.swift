import Foundation
import LagoonEngine

/// Letters-only and API version segments survive; everything else becomes
/// `{id}`: `Users/{id}/Items/{id}/PlaybackInfo`. A reverse-proxy base path
/// is removed first so routes group across servers.
nonisolated enum DiagnosticRouteTemplate {
    static let maximumSegments = 8

    /// `v` plus digits only, kept because Seerr mounts everything under
    /// `api/v1`. Keep the exception this narrow: ids, UUIDs, slugs and file
    /// names must still become `{id}` so nothing identifying leaves.
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

/// Which request failures are worth a report: not an unreachable server, a
/// lost connection or a cancel; yes to TLS failures, bad URLs and rejected
/// responses.
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

    /// Not faults: 401, 403 (the subtitle permission) and 304.
    static func isExpectedStatus(_ status: Int) -> Bool {
        status == 401 || status == 403 || status == 304
    }
}

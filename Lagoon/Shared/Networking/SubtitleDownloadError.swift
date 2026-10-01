import Foundation
import LagoonEngine

/// Why a subtitle search or download failed, specific enough for the viewer
/// to act on.
nonisolated enum SubtitleDownloadError: LocalizedError, Equatable {
    case notAvailable
    case providerUnavailable
    case unsupportedFile
    case invalidFile
    case tooLarge
    case notPermitted
    case sessionExpired
    case rateLimited
    case timedOut
    case offline
    case server(Int)
    /// The server's own explanation, which beats any wording invented here.
    case reported(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            "Jellyfin did not attach this subtitle to the item. Try another result."
        case .providerUnavailable:
            "The subtitle provider could not supply this file. It may have been removed or the provider's download limit may have been reached. Try another result."
        case .unsupportedFile:
            "The subtitle provider returned a file Lagoon couldn't read. Try another result."
        case .invalidFile:
            "The server returned an incomplete or invalid subtitle file. Try another result."
        case .tooLarge:
            "This subtitle exceeds Lagoon's 8 MB download limit. Choose another result or track."
        case .notPermitted:
            "Subtitle search isn't enabled for your account. Ask your server administrator to turn on “Allow subtitle management”."
        case .sessionExpired:
            "This Jellyfin session has expired. Sign in again to download subtitles."
        case .rateLimited:
            "The subtitle provider is rate-limiting requests right now. Try again in a few minutes."
        case .timedOut:
            "The subtitle provider didn't respond in time. Try again."
        case .offline:
            "Lagoon couldn't reach the Jellyfin server."
        case .server(let status):
            "Jellyfin returned an error (\(status))."
        case .reported(let status, let message):
            "\(message) (\(status))"
        }
    }

    /// The HTTP status behind this, if any. Branch on this, not case equality,
    /// so a failure that carries a message still matches.
    var httpStatus: Int? {
        switch self {
        case .server(let status), .reported(let status, _): status
        case .notPermitted: 403
        case .sessionExpired: 401
        case .rateLimited: 429
        default: nil
        }
    }

    /// Maps transport failures onto a cause the viewer can act on. Anything
    /// unrecognised stays a server error.
    static func classify(_ error: Error) -> SubtitleDownloadError {
        if let known = error as? SubtitleDownloadError { return known }
        if let download = error as? DownloadFailure {
            switch download {
            case .tooLarge: return .tooLarge
            case .httpStatus(let status, let body):
                return classify(JellyfinError.server(status: status, message: JellyfinClient.serverMessage(from: body)))
            case .invalidResponse, .unexpectedContentType, .truncated, .unsafeRedirect: return .invalidFile
            }
        }
        if let jellyfin = error as? JellyfinError {
            switch jellyfin {
            case .unauthorized, .sessionExpired:
                return .sessionExpired
            case .server(let status, let message):
                // Own wording for the cases we understand, the server's otherwise.
                switch status {
                case 401: return .sessionExpired
                case 403: return .notPermitted
                case 429: return .rateLimited
                default: break
                }
                if let message, !message.isEmpty {
                    return .reported(status: status, message: message)
                }
                return (500...599).contains(status) ? .providerUnavailable : .server(status)
            default:
                return .server(0)
            }
        }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return .timedOut
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .offline
            default:
                return .server(url.errorCode)
            }
        }
        return .server(0)
    }

    /// Only failures that fail fast and may succeed on a second try. Not a
    /// timeout (the budget is already 90 s) and not rate limiting (it lasts
    /// minutes, and retrying spends quota).
    var isRetryable: Bool {
        switch self {
        case .offline, .providerUnavailable:
            true
        case .reported(let status, _):
            (500...599).contains(status)
        case .timedOut, .rateLimited, .notPermitted, .sessionExpired,
             .unsupportedFile, .invalidFile, .tooLarge, .notAvailable, .server:
            false
        }
    }
}

/// Provider searches reach third-party services through the server and
/// outlast the client-wide 30 s budget.
nonisolated enum SubtitleRequestTimeout {
    static let provider: TimeInterval = 90
}

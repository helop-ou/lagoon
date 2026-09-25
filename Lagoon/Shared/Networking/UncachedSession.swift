import Foundation

/// A `URLSession` with no shared cache and no cookie jar, so a client's
/// traffic never touches another client's storage or the app's shared URL
/// cache.
nonisolated enum UncachedSession {
    static func make(
        base: URLSessionConfiguration = .ephemeral,
        waitsForConnectivity: Bool,
        timeoutIntervalForRequest: TimeInterval? = nil,
        timeoutIntervalForResource: TimeInterval? = nil
    ) -> URLSession {
        let configuration = base
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = waitsForConnectivity
        if let timeoutIntervalForRequest {
            configuration.timeoutIntervalForRequest = timeoutIntervalForRequest
        }
        if let timeoutIntervalForResource {
            configuration.timeoutIntervalForResource = timeoutIntervalForResource
        }
        return URLSession(configuration: configuration)
    }
}

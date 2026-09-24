import Foundation
@testable import Lagoon

/// A canned-response `URLProtocol` stub for fixture suites that just map a
/// request to a fixed status, headers and body (or an error) by host.
/// Suites with holds, streaming, byte-range serving or other extra modes
/// keep their own `URLProtocol` subclass; this only covers the simple case.
nonisolated final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)

    private struct State {
        var handlers: [String: Handler] = [:]
        var requests: [String: [URLRequest]] = [:]
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var state = State()

    /// Registers (or replaces) the handler for `host`. Suites run in
    /// parallel, so each fixture file uses its own host.
    static func register(host: String, handler: @escaping Handler) {
        lock.withLock {
            state.handlers[host] = handler
            state.requests[host] = []
        }
    }

    static func unregister(host: String) {
        lock.withLock {
            state.handlers.removeValue(forKey: host)
            state.requests.removeValue(forKey: host)
        }
    }

    static func requests(host: String) -> [URLRequest] {
        lock.withLock { state.requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { state.handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.lock.withLock({ Self.state.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.lock.withLock { Self.state.requests[host, default: []].append(request) }
        do {
            let (status, headers, body) = try handler(request)
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// An ephemeral session configuration routed through this stub.
    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }

    /// Builds a configured, signed-in `JellyfinClient` against `host`
    /// through this stub, the way most fixture suites construct one.
    static func makeJellyfinClient(
        host: String,
        deviceId: String,
        token: String = "token",
        userId: String = "user"
    ) -> JellyfinClient {
        let client = JellyfinClient(deviceId: deviceId, sessionConfiguration: configuration())
        client.configure(serverURL: URL(string: "https://\(host)")!)
        client.activateSession(token: token, userId: userId)
        return client
    }
}

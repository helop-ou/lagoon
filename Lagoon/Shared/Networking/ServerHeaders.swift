import Foundation
import os

/// A header a forward-auth proxy in front of a server wants on every request,
/// such as Cloudflare Access's `CF-Access-Client-Id` and `-Secret`. The value
/// is a credential.
nonisolated struct CustomHTTPHeader: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var value: String

    init(name: String = "", value: String = "") {
        self.name = name
        self.value = value
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Headers Lagoon sets itself, Jellyfin reads as its own token, or
    /// URLSession owns; a proxy header may not replace them.
    static let reservedNames: Set<String> = [
        "authorization", "cookie", "host", "content-type", "content-length",
        "accept", "connection", "range", "user-agent",
        "proxy-authorization", "proxy-authenticate", "www-authenticate",
        "transfer-encoding", "upgrade",
        "x-emby-authorization", "x-emby-token", "x-mediabrowser-token",
    ]

    /// An RFC 9110 token: what a header name may contain.
    static func isValidName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~")
            .union(CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        return !name.isEmpty && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    /// No control characters, so a value can never end the header line.
    static func isValidValue(_ value: String) -> Bool {
        !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    enum Problem: Error, Equatable {
        case invalidName(String)
        case reservedName(String)
        case duplicateName(String)
        case missingValue(String)
        case invalidValue(String)

        var message: String {
            switch self {
            case .invalidName(let name):
                "“\(name)” is not a valid header name. Use letters, digits and hyphens."
            case .reservedName(let name):
                "Lagoon sets \(name) itself, so it can't be a custom header."
            case .duplicateName(let name):
                "\(name) is listed twice."
            case .missingValue(let name):
                "\(name) needs a value."
            case .invalidValue(let name):
                "\(name) has a character a header can't carry, such as a line break."
            }
        }
    }

    /// The rows worth keeping: blank rows are dropped, anything else must be
    /// a complete, valid, unreserved header.
    static func validated(_ headers: [CustomHTTPHeader]) -> Result<[CustomHTTPHeader], Problem> {
        var kept: [CustomHTTPHeader] = []
        var seen: Set<String> = []
        for header in headers {
            let name = header.trimmedName
            let value = header.trimmedValue
            if name.isEmpty && value.isEmpty { continue }
            guard isValidName(name) else { return .failure(.invalidName(name)) }
            let lowered = name.lowercased()
            guard !reservedNames.contains(lowered), !lowered.hasPrefix("sec-websocket-") else {
                return .failure(.reservedName(name))
            }
            guard seen.insert(name.lowercased()).inserted else { return .failure(.duplicateName(name)) }
            guard !value.isEmpty else { return .failure(.missingValue(name)) }
            guard isValidValue(value) else { return .failure(.invalidValue(name)) }
            var clean = CustomHTTPHeader(name: name, value: value)
            clean.id = header.id
            kept.append(clean)
        }
        return .success(kept)
    }
}

/// Custom headers for a Jellyfin or Seerr server behind a forward-auth proxy.
/// Sent only over HTTPS and its socket form, WSS: a fallback to plain HTTP
/// must never carry a proxy secret in clear.
///
/// Stored per host, in scopes. While connecting, headers sit in the host-wide
/// scope, because connecting tries several schemes and ports for the host the
/// viewer typed; once a server answers, `narrow(toServer:)` moves them to that
/// server's port and path. So a Jellyfin and a Seerr on one host, at different
/// ports or paths, keep separate headers, and a request gets the most specific
/// scope that covers it.
///
/// One keychain item per host holds every scope, since the values are
/// credentials. Reads are cached, because every request asks.
nonisolated final class ServerHeaderStore: Sendable {
    static let shared = ServerHeaderStore(credentials: SystemAccountCredentials())

    /// A port and a path prefix on one host, as "443/jellyfin"; "" covers the
    /// whole host.
    typealias Scope = String
    static let hostWide: Scope = ""

    private let credentials: AccountCredentialStorage
    private struct State {
        var cache: [String: [Scope: [CustomHTTPHeader]]] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init(credentials: AccountCredentialStorage) {
        self.credentials = credentials
    }

    static func keychainAccount(forHost host: String) -> String {
        "server-headers:\(host.lowercased())"
    }

    /// The scope a server's base URL, or a request to it, falls in.
    static func scope(for url: URL) -> Scope {
        "\(port(of: url))\(normalizedPath(url.path()))"
    }

    private static func port(of url: URL) -> Int {
        url.port ?? (["https", "wss"].contains(url.scheme?.lowercased()) ? 443 : 80)
    }

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.split(separator: "/").joined(separator: "/")
        return trimmed.isEmpty ? "" : "/" + trimmed.lowercased()
    }

    private func scopes(forHost host: String) -> [Scope: [CustomHTTPHeader]] {
        state.withLock { state in
            if let cached = state.cache[host] { return cached }
            let stored = credentials.string(for: Self.keychainAccount(forHost: host)).map { Data($0.utf8) }
            let decoded = stored.flatMap { try? JSONDecoder().decode([Scope: [CustomHTTPHeader]].self, from: $0) }
                // Stored before scopes existed: the whole host.
                ?? stored.flatMap { try? JSONDecoder().decode([CustomHTTPHeader].self, from: $0) }.map { [Self.hostWide: $0] }
                ?? [:]
            state.cache[host] = decoded
            return decoded
        }
    }

    private func save(_ scopes: [Scope: [CustomHTTPHeader]], forHost host: String) throws {
        let kept = scopes.filter { !$0.value.isEmpty }
        let account = Self.keychainAccount(forHost: host)
        if kept.isEmpty {
            try? credentials.delete(account)
        } else {
            let data = try JSONEncoder().encode(kept)
            try credentials.set(String(decoding: data, as: UTF8.self), for: account)
        }
        state.withLock { $0.cache[host] = kept }
    }

    /// Every header stored for the host, in any scope: what a redirect off the
    /// host must strip.
    func headers(forHost host: String?) -> [CustomHTTPHeader] {
        guard let host = host?.lowercased(), !host.isEmpty else { return [] }
        return scopes(forHost: host).sorted { $0.key < $1.key }.flatMap(\.value)
    }

    /// The headers of the most specific scope covering `url`.
    func headers(for url: URL) -> [CustomHTTPHeader] {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return [] }
        let port = "\(Self.port(of: url))"
        let path = Self.normalizedPath(url.path())
        let matching = scopes(forHost: host).filter { scope, _ in
            guard scope != Self.hostWide else { return true }
            guard scope.hasPrefix(port) else { return false }
            let scopePath = scope.dropFirst(port.count)
            guard scopePath.isEmpty || scopePath.hasPrefix("/") else { return false }
            return scopePath.isEmpty || path == scopePath || path.hasPrefix(scopePath + "/")
        }
        return matching.max { $0.key.count < $1.key.count }?.value ?? []
    }

    /// Replaces one scope's headers on the host; an empty list removes them.
    func setHeaders(_ headers: [CustomHTTPHeader], forHost host: String, scope: Scope = hostWide) throws {
        let host = host.lowercased()
        var scopes = scopes(forHost: host)
        scopes[scope] = headers
        try save(scopes, forHost: host)
    }

    /// Replaces the headers of the server at `url`.
    func setHeaders(_ headers: [CustomHTTPHeader], forServer url: URL) throws {
        guard let host = url.host() else { return }
        try setHeaders(headers, forHost: host, scope: Self.scope(for: url))
    }

    /// Every scope on the host.
    func removeHeaders(forHost host: String) {
        try? save([:], forHost: host.lowercased())
    }

    func removeHeaders(forServer url: URL) {
        try? setHeaders([], forServer: url)
    }

    /// Saves validated headers for the host `input` names, host-wide, before
    /// the first request to it. Returns an undo that puts back what was
    /// staged before, for a connection that fails.
    @discardableResult
    func stage(
        _ headers: [CustomHTTPHeader],
        for input: String,
        service: ServerAddress.Service
    ) throws -> (@Sendable () -> Void) {
        let valid = try CustomHTTPHeader.validated(headers).get()
        guard !valid.isEmpty,
              let host = ServerAddress.candidateURLs(for: input, service: service).first?.host() else {
            return {}
        }
        let previous = scopes(forHost: host.lowercased())[Self.hostWide] ?? []
        try setHeaders(valid, forHost: host)
        return { [self] in try? setHeaders(previous, forHost: host) }
    }

    /// Moves headers staged for the whole host to the server that answered.
    /// A server reached over plain HTTP could never receive them, so they go.
    func narrow(toServer url: URL) {
        guard let host = url.host()?.lowercased() else { return }
        var scopes = scopes(forHost: host)
        guard let staged = scopes.removeValue(forKey: Self.hostWide), !staged.isEmpty else { return }
        if Self.isSecure(url) { scopes[Self.scope(for: url)] = staged }
        try? save(scopes, forHost: host)
    }

    static func isSecure(_ url: URL?) -> Bool {
        ["https", "wss"].contains(url?.scheme?.lowercased())
    }

    /// The headers for `url`, when it is HTTPS or WSS; empty otherwise.
    func fields(for url: URL?) -> [String: String] {
        guard let url, Self.isSecure(url) else { return [:] }
        return Dictionary(
            headers(for: url).map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    /// Adds the host's headers to a request aimed at it, without replacing
    /// anything the request already sets.
    func apply(to request: inout URLRequest) {
        for (name, value) in fields(for: request.url) where request.value(forHTTPHeaderField: name) == nil {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    /// A redirect keeps a host's headers only while it stays on that host
    /// over HTTPS. Otherwise they are removed. Either way the new target's are
    /// applied, so an upgrade from HTTP to HTTPS on the same host gains them.
    func redirected(_ request: URLRequest, from original: URL?) -> URLRequest {
        guard let original else { return request }
        var request = request
        let staysOnHost = request.url?.host()?.lowercased() == original.host()?.lowercased()
            && Self.isSecure(request.url)
        if !staysOnHost {
            for header in headers(forHost: original.host()) {
                request.setValue(nil, forHTTPHeaderField: header.name)
            }
        }
        apply(to: &request)
        return request
    }
}

/// Installed on the app's own sessions, so a redirect never carries one
/// server's proxy headers to another host.
nonisolated final class ServerHeaderRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = ServerHeaderRedirectGuard(store: .shared)

    private let store: ServerHeaderStore

    init(store: ServerHeaderStore) {
        self.store = store
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(store.redirected(request, from: response.url ?? task.originalRequest?.url))
    }
}

extension URLRequest {
    /// This request with its server's proxy headers, if it has any.
    nonisolated func withServerHeaders(_ store: ServerHeaderStore = .shared) -> URLRequest {
        var request = self
        store.apply(to: &request)
        return request
    }
}

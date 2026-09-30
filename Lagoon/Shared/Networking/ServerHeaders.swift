import Foundation

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

/// Custom headers per server host, for a Jellyfin or Seerr server behind a
/// forward-auth proxy. Keyed by host, not address, because connecting tries
/// several schemes and ports for the one host the viewer typed. Sent only over
/// HTTPS and its socket form, WSS: a fallback to plain HTTP must never carry a
/// proxy secret in clear.
///
/// Names and values live together in the keychain, since the values are
/// credentials. Reads are cached, because every request asks.
nonisolated final class ServerHeaderStore: @unchecked Sendable {
    static let shared = ServerHeaderStore(credentials: SystemAccountCredentials())

    private let credentials: AccountCredentialStorage
    private let lock = NSLock()
    private var cache: [String: [CustomHTTPHeader]] = [:]

    init(credentials: AccountCredentialStorage) {
        self.credentials = credentials
    }

    static func keychainAccount(forHost host: String) -> String {
        "server-headers:\(host.lowercased())"
    }

    func headers(forHost host: String?) -> [CustomHTTPHeader] {
        guard let host = host?.lowercased(), !host.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[host] { return cached }
        let stored = credentials.string(for: Self.keychainAccount(forHost: host))
            .flatMap { try? JSONDecoder().decode([CustomHTTPHeader].self, from: Data($0.utf8)) } ?? []
        cache[host] = stored
        return stored
    }

    /// Replaces the host's headers; an empty list removes them.
    func setHeaders(_ headers: [CustomHTTPHeader], forHost host: String) throws {
        let host = host.lowercased()
        let account = Self.keychainAccount(forHost: host)
        if headers.isEmpty {
            try? credentials.delete(account)
        } else {
            let data = try JSONEncoder().encode(headers)
            try credentials.set(String(decoding: data, as: UTF8.self), for: account)
        }
        lock.lock()
        cache[host] = headers
        lock.unlock()
    }

    func removeHeaders(forHost host: String) {
        try? setHeaders([], forHost: host)
    }

    static func isSecure(_ url: URL?) -> Bool {
        ["https", "wss"].contains(url?.scheme?.lowercased())
    }

    /// The headers for `url`, when it is HTTPS or WSS; empty otherwise.
    func fields(for url: URL?) -> [String: String] {
        guard let url, Self.isSecure(url) else { return [:] }
        return Dictionary(
            headers(forHost: url.host()).map { ($0.name, $0.value) },
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
nonisolated final class ServerHeaderRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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

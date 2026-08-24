import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum JellyfinError: LocalizedError {
    case notConfigured
    case invalidServerURL
    case unauthorized
    /// `message` is whatever the server said in the body. Jellyfin wraps a
    /// provider's exception into a 500 and puts the real reason there — an
    /// exhausted OpenSubtitles quota, for instance — so discarding it left
    /// the UI guessing between causes it could have simply read (HEL-98).
    case server(status: Int, message: String? = nil)
    case unplayable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Not connected to a server."
        case .invalidServerURL: "That doesn't look like a valid server address."
        case .unauthorized: "Wrong username or password."
        case .server(let status, let message):
            if let message, !message.isEmpty {
                "\(message) (\(status))"
            } else {
                "The server returned an error (\(status))."
            }
        case .unplayable: "This item can't be played on this device."
        }
    }
}

/// Thin async HTTP client for a single Jellyfin server.
///
/// Jellyfin JSON is PascalCase on the wire; the decoder and encoder convert
/// key casing globally so model types stay camelCase with no CodingKeys.
final class JellyfinClient {
    static let clientName = "Lagoon"

    private(set) var serverURL: URL?
    private(set) var accessToken: String?
    private(set) var userId: String?
    let deviceId: String
    /// Resolved once per session: sign-in carries the policy, a restored
    /// token does not, so this is filled from whichever arrives first.
    private var subtitleManagementAllowed: Bool?

    private let session: URLSession

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyCodingKey(stringLiteral: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }()

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyCodingKey(stringLiteral: key.prefix(1).uppercased() + key.dropFirst())
        }
        return encoder
    }()

    init(
        deviceId: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.deviceId = deviceId
        let config = sessionConfiguration
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: - Session state

    func configure(serverURL: URL) {
        self.serverURL = serverURL
    }

    func activateSession(token: String, userId: String, policy: UserPolicy? = nil) {
        accessToken = token
        self.userId = userId
        subtitleManagementAllowed = policy?.allowsSubtitleManagement
    }

    func clearSession() {
        accessToken = nil
        userId = nil
        subtitleManagementAllowed = nil
    }

    /// Whether this account may use Jellyfin's remote-subtitle endpoints.
    /// Every one of them answers 403 without the permission, so asking once
    /// is what lets the UI say so plainly instead of failing per result.
    /// An unreachable server answers `true`: a network problem must not be
    /// reported to the viewer as a permissions problem.
    func canManageSubtitles() async -> Bool {
        if let subtitleManagementAllowed { return subtitleManagementAllowed }
        guard let user = try? await currentUser() else { return true }
        let allowed = user.policy?.allowsSubtitleManagement ?? true
        subtitleManagementAllowed = allowed
        return allowed
    }

    func currentUser() async throws -> UserDto {
        try await get("Users/Me")
    }

    var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    private var deviceName: String {
        #if os(tvOS)
        "Apple TV"
        #elseif canImport(UIKit)
        UIDevice.current.model
        #else
        "Apple Device"
        #endif
    }

    var authorizationHeader: String {
        var header = #"MediaBrowser Client="\#(Self.clientName)", Device="\#(deviceName)", DeviceId="\#(deviceId)", Version="\#(appVersion)""#
        if let accessToken {
            header += #", Token="\#(accessToken)""#
        }
        return header
    }

    // MARK: - Requests

    func requireUserId() throws -> String {
        guard let userId else { throw JellyfinError.notConfigured }
        return userId
    }

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let serverURL else { throw JellyfinError.notConfigured }
        guard var components = URLComponents(url: serverURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw JellyfinError.invalidServerURL
        }
        if !query.isEmpty {
            components.queryItems = query
        }
        guard let url = components.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    /// Builds a route from individually encoded path components. Opaque API
    /// ids (notably subtitle-provider ids) may contain `/`, `?`, `%`, or `#`;
    /// interpolating one into a path would change the route or double-encode
    /// it instead of sending it as the single component Jellyfin expects.
    func url(pathComponents: [String], query: [URLQueryItem] = []) throws -> URL {
        guard let serverURL,
              var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            throw JellyfinError.notConfigured
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        let encoded = try pathComponents.map { component in
            guard let value = component.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw JellyfinError.invalidServerURL
            }
            return value
        }
        var path = components.percentEncodedPath
        if !path.hasSuffix("/") { path += "/" }
        components.percentEncodedPath = path + encoded.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw JellyfinError.invalidServerURL }
        return url
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "GET"))
    }

    func getData(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await data(for: request(for: url(path: path, query: query), method: "GET"))
    }

    func get<T: Decodable>(
        _ pathComponents: [String],
        query: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) async throws -> T {
        try await send(request(
            for: url(pathComponents: pathComponents, query: query),
            method: "GET",
            timeout: timeout
        ))
    }

    func getData(
        _ pathComponents: [String],
        query: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        try await data(for: request(
            for: url(pathComponents: pathComponents, query: query),
            method: "GET",
            timeout: timeout
        ))
    }

    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "POST"))
    }

    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: some Encodable) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "POST", body: Self.encoder.encode(body)))
    }

    func postVoid(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "POST"))
    }

    func postVoid(_ path: String, query: [URLQueryItem] = [], body: some Encodable) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "POST", body: Self.encoder.encode(body)))
    }

    func postVoid(
        _ pathComponents: [String],
        query: [URLQueryItem] = [],
        timeout: TimeInterval? = nil
    ) async throws {
        _ = try await data(for: request(
            for: url(pathComponents: pathComponents, query: query),
            method: "POST",
            timeout: timeout
        ))
    }

    func postVoid(
        _ pathComponents: [String],
        query: [URLQueryItem] = [],
        body: some Encodable
    ) async throws {
        _ = try await data(for: request(
            for: url(pathComponents: pathComponents, query: query),
            method: "POST",
            body: Self.encoder.encode(body)
        ))
    }

    func deleteVoid(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await data(for: request(for: url(path: path, query: query), method: "DELETE"))
    }

    private func request(
        for url: URL,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval? = nil
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data = try await data(for: request)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.server(status: 0) }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            throw JellyfinError.unauthorized
        default:
            throw JellyfinError.server(
                status: http.statusCode,
                message: Self.serverMessage(from: data)
            )
        }
    }

    /// Pulls a human sentence out of an error body. Jellyfin answers with
    /// problem-details JSON, plain text, or an HTML page depending on where
    /// the failure happened; only the first two say anything worth showing.
    static func serverMessage(from data: Data) -> String? {
        guard !data.isEmpty, data.count < 64 * 1_024 else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["detail", "title", "message", "Message", "error"] {
                if let value = object[key] as? String {
                    return condensed(value)
                }
            }
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // An HTML error page is the server's chrome, not its explanation.
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else { return nil }
        return condensed(text)
    }

    private static func condensed(_ value: String) -> String? {
        let clean = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        return clean.count > 180 ? String(clean.prefix(180)) + "…" : clean
    }

    // MARK: - Server probe (pre-auth, arbitrary URL)

    nonisolated static func fetchPublicInfo(at serverURL: URL) async throws -> PublicSystemInfo {
        var request = URLRequest(url: serverURL.appending(path: "System/Info/Public"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JellyfinError.invalidServerURL
        }
        return try decoder.decode(PublicSystemInfo.self, from: data)
    }
}

// MARK: - Auth endpoints

extension JellyfinClient {
    nonisolated struct AuthenticateByNameRequest: Encodable {
        let username: String
        let pw: String
    }

    nonisolated struct QuickConnectAuthRequest: Encodable {
        let secret: String
    }

    func authenticateByName(username: String, password: String) async throws -> AuthenticationResult {
        try await post("Users/AuthenticateByName", body: AuthenticateByNameRequest(username: username, pw: password))
    }

    func quickConnectEnabled() async throws -> Bool {
        try await get("QuickConnect/Enabled")
    }

    func initiateQuickConnect() async throws -> QuickConnectResult {
        try await post("QuickConnect/Initiate")
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await get("QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)])
    }

    /// Approves a Quick Connect code on behalf of the signed-in user — the
    /// other half of the handshake, performed by a client that is *already*
    /// authenticated. Normally that is your phone approving a television;
    /// Lagoon uses it to approve a code Jellyseerr asked Jellyfin for, which
    /// is how Seerr can be signed into without a password (HEL-95).
    ///
    /// Verified against Jellyfin 10.11: a client may authorise a code for its
    /// own user, and the requesting side's `Connect` immediately reports
    /// authenticated.
    @discardableResult
    func authorizeQuickConnect(code: String) async throws -> Bool {
        try await post("QuickConnect/Authorize", query: [URLQueryItem(name: "code", value: code)])
    }

    func authenticateWithQuickConnect(secret: String) async throws -> AuthenticationResult {
        try await post("Users/AuthenticateWithQuickConnect", body: QuickConnectAuthRequest(secret: secret))
    }

    func logout() async throws {
        try await postVoid("Sessions/Logout")
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
#endif

nonisolated enum JellyfinError: LocalizedError {
    case notConfigured
    case invalidServerURL
    case unauthorized
    case sessionExpired
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
        case .sessionExpired: "Your session expired. Sign in again to continue."
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
    /// Identity only: no credential in callbacks, diagnostics or persistence.
    nonisolated struct SessionIdentity: Equatable, Sendable {
        let generation: UUID
        let serverURL: URL
        let userId: String
    }
    private var sessionGeneration = UUID()
    var onSessionExpired: ((SessionIdentity) -> Void)?
    var sessionIdentity: SessionIdentity? {
        guard accessToken != nil, let serverURL, let userId else { return nil }
        return SessionIdentity(generation: sessionGeneration, serverURL: serverURL, userId: userId)
    }
    /// Playback sessions whose stop report is still in flight. Screens that
    /// re-fetch after the player closes wait on it first (HEL-132).
    let playbackReports = PlaybackReportLedger()
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
        // Nothing this session fetches is worth caching (images and the
        // playback cache have their own sessions), and see `request(for:)`.
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    // MARK: - Session state

    func configure(serverURL: URL) {
        if self.serverURL != serverURL { clearSession() }
        self.serverURL = serverURL
    }

    func activateSession(token: String, userId: String, policy: UserPolicy? = nil) {
        sessionGeneration = UUID()
        accessToken = token
        self.userId = userId
        subtitleManagementAllowed = policy?.allowsSubtitleManagement
    }

    func clearSession() {
        sessionGeneration = UUID()
        accessToken = nil
        userId = nil
        subtitleManagementAllowed = nil
    }

    /// An independent client for work that may outlive a view/account change.
    /// It never consults or mutates the active client's later credentials.
    func sessionSnapshot() -> JellyfinClient {
        let copy = JellyfinClient(deviceId: deviceId, sessionConfiguration: session.configuration)
        if let serverURL { copy.configure(serverURL: serverURL) }
        if let accessToken, let userId { copy.activateSession(token: accessToken, userId: userId) }
        return copy
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
        authorizationHeader(token: accessToken)
    }

    private func authorizationHeader(token: String?) -> String {
        var header = #"MediaBrowser Client="\#(Self.clientName)", Device="\#(deviceName)", DeviceId="\#(deviceId)", Version="\#(appVersion)""#
        if let token {
            header += #", Token="\#(token)""#
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

    private struct PreparedRequest {
        let request: URLRequest
        let session: SessionIdentity?
    }

    private func request(
        for url: URL,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        authenticated: Bool = true
    ) -> PreparedRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Never answer an API call from the HTTP cache: these responses carry
        // per-user state (resume points, played flags) that the app has just
        // changed with a report, and a cached copy is exactly the position
        // from before (HEL-132).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader(token: authenticated ? accessToken : nil), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return PreparedRequest(request: request, session: authenticated ? sessionIdentity : nil)
    }

    private func send<T: Decodable>(_ request: PreparedRequest) async throws -> T {
        let data = try await data(for: request)
        return try Self.decoder.decode(T.self, from: data)
    }

    private func data(for request: PreparedRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request.request)
        // A response belongs to the session captured before suspension. Even
        // a successful old response must not update the new account's screen.
        if let identity = request.session, identity != sessionIdentity { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw JellyfinError.server(status: 0) }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            if let identity = request.session {
                clearSession()
                onSessionExpired?(identity)
                throw JellyfinError.sessionExpired
            }
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

    private nonisolated static let serverProbeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    nonisolated static func fetchPublicInfo(at serverURL: URL) async throws -> PublicSystemInfo {
        var request = URLRequest(url: serverURL.appending(path: "System/Info/Public"))
        request.timeoutInterval = 10
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await serverProbeSession.data(for: request)
        } catch {
            throw await LocalNetworkAccess.explain(error, at: serverURL)
        }
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
        try await send(request(for: url(path: "Users/AuthenticateByName"), method: "POST",
                               body: Self.encoder.encode(AuthenticateByNameRequest(username: username, pw: password)),
                               authenticated: false))
    }

    func quickConnectEnabled() async throws -> Bool {
        try await send(request(for: url(path: "QuickConnect/Enabled"), method: "GET", authenticated: false))
    }

    func initiateQuickConnect() async throws -> QuickConnectResult {
        try await send(request(for: url(path: "QuickConnect/Initiate"), method: "POST", authenticated: false))
    }

    func quickConnectState(secret: String) async throws -> QuickConnectResult {
        try await send(request(for: url(path: "QuickConnect/Connect", query: [URLQueryItem(name: "secret", value: secret)]),
                               method: "GET", authenticated: false))
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
        try await send(request(for: url(path: "Users/AuthenticateWithQuickConnect"), method: "POST",
                               body: Self.encoder.encode(QuickConnectAuthRequest(secret: secret)), authenticated: false))
    }

    func logout() async throws {
        try await postVoid("Sessions/Logout")
    }
}

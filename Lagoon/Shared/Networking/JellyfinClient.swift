import Foundation
import LagoonEngine
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
    /// the UI guessing between causes it could have simply read.
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
    /// re-fetch after the player closes wait on it first.
    let playbackReports = PlaybackReportLedger()
    /// Resolved once per session: sign-in carries the policy, a restored
    /// token does not, so this is filled from whichever arrives first.
    private var subtitleManagementAllowed: Bool?
    /// Resolved once per session, same as subtitle management, but for
    /// "Allow media downloading". Unlike subtitles, an unknown
    /// answer must not let a download start, so this defaults to false
    /// rather than true; see `canDownloadContent()`.
    private var contentDownloadingAllowed: Bool?
    /// Resolved once per session, same pattern as content downloading, but
    /// for "Allow video transcoding": whether the server will build a
    /// High/Standard transcoded download for this account. Same
    /// opposite-of-subtitles default; see `canTranscodeForDownload()`.
    private var videoTranscodingAllowed: Bool?

    /// The value `contentDownloadingAllowed` holds right now, for view code
    /// that must answer synchronously while building a menu body. `nil`
    /// until something has resolved it this session; a `.task` should call
    /// `canDownloadContent()` once to warm it.
    var cachedContentDownloadingAllowed: Bool? { contentDownloadingAllowed }
    /// The value `videoTranscodingAllowed` holds right now; see
    /// `cachedContentDownloadingAllowed`.
    var cachedVideoTranscodingAllowed: Bool? { videoTranscodingAllowed }

    private let session: URLSession
    private let downloads: BoundedDownload

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
        downloads = BoundedDownload(configuration: config)
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
        contentDownloadingAllowed = policy?.isAdministrator == true ? true : policy?.enableContentDownloading
        videoTranscodingAllowed = policy?.isAdministrator == true ? true : policy?.enableVideoPlaybackTranscoding
    }

    func clearSession() {
        sessionGeneration = UUID()
        accessToken = nil
        userId = nil
        subtitleManagementAllowed = nil
        contentDownloadingAllowed = nil
        videoTranscodingAllowed = nil
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

    /// Re-asks the server for the account's subtitle permission, for the
    /// Settings status that must reflect a flag an administrator turned on
    /// after sign-in. nil when the server could not be reached, so
    /// the caller can say "couldn't check" rather than "not enabled".
    func refreshSubtitlePermission() async -> Bool? {
        guard let user = try? await currentUser() else { return nil }
        let allowed = user.policy?.allowsSubtitleManagement ?? true
        subtitleManagementAllowed = allowed
        return allowed
    }

    /// Whether the account may take a title off the server at all.
    /// Opposite default from subtitles: since a network problem here must
    /// not let a download start against a server that would refuse it, an
    /// answer that was never learned and a refresh that fails both mean no,
    /// not yes. Administrators pass regardless of the flag, same reasoning
    /// as `allowsSubtitleManagement`.
    func canDownloadContent() async -> Bool {
        if let contentDownloadingAllowed { return contentDownloadingAllowed }
        return await refreshContentDownloadingPermission() ?? false
    }

    /// Re-asks the server, for a permission an administrator could have
    /// turned on after sign-in. Returns the last known value (nil the first
    /// time) when the server can't be reached, rather than flipping to no.
    @discardableResult
    func refreshContentDownloadingPermission() async -> Bool? {
        let identity = sessionIdentity
        let user = try? await currentUser()
        // A failed request can be an old session's cancelled response. Its
        // caller must not receive the newly selected account's cached policy.
        guard identity == sessionIdentity, !Task.isCancelled else { return nil }
        guard let user else { return contentDownloadingAllowed }
        if user.policy?.isAdministrator == true {
            contentDownloadingAllowed = true
            return true
        }
        let allowed = user.policy?.enableContentDownloading
        if let allowed {
            contentDownloadingAllowed = allowed
        }
        return allowed ?? contentDownloadingAllowed
    }

    /// Whether the account may have the server build a transcoded download
    /// (High/Standard quality) for offline playback, rather than only the
    /// original file. Same opposite-default reasoning as
    /// `canDownloadContent()`: an unknown or unreachable answer means no.
    /// Administrators pass regardless of the flag.
    func canTranscodeForDownload() async -> Bool {
        if let videoTranscodingAllowed { return videoTranscodingAllowed }
        return await refreshVideoTranscodingPermission() ?? false
    }

    /// Re-asks the server, for a permission an administrator could have
    /// turned on after sign-in. Returns the last known value (nil the first
    /// time) when the server can't be reached, rather than flipping to no.
    @discardableResult
    func refreshVideoTranscodingPermission() async -> Bool? {
        let identity = sessionIdentity
        let user = try? await currentUser()
        guard identity == sessionIdentity, !Task.isCancelled else { return nil }
        guard let user else { return videoTranscodingAllowed }
        if user.policy?.isAdministrator == true {
            videoTranscodingAllowed = true
            return true
        }
        let allowed = user.policy?.enableVideoPlaybackTranscoding
        if let allowed {
            videoTranscodingAllowed = allowed
        }
        return allowed ?? videoTranscodingAllowed
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

    /// The header form of the media credential, for transports that would
    /// otherwise carry it in the URL. nil while signed out.
    func mediaRequestAuthorization() -> MediaRequestAuthorization? {
        guard let serverURL, let accessToken else { return nil }
        return MediaRequestAuthorization(
            origin: serverURL,
            headerName: "Authorization",
            headerValue: authorizationHeader(token: accessToken),
            queryNames: ["apikey", "api_key"]
        )
    }

    // MARK: - Requests

    func requireUserId() throws -> String {
        guard let userId else { throw JellyfinError.notConfigured }
        return userId
    }

    /// Resolves a server-relative route Jellyfin hands back inside a
    /// response body — a `TranscodingUrl` or a subtitle `DeliveryUrl`, in
    /// absolute-path form with its own query — against the configured
    /// server, keeping a reverse-proxy base path such as
    /// `https://host/jellyfin`. `URL(string:relativeTo:)` discards that
    /// path for an absolute-path reference, which is how every transcode
    /// and external subtitle on a base-path server resolved to the wrong
    /// route until the regression lane hit demo.jellyfin.org/stable.
    /// A reference that is already absolute is returned as given.
    func serverRelativeURL(_ reference: String) -> URL? {
        guard let serverURL, let reference = URLComponents(string: reference) else { return nil }
        if reference.scheme != nil || reference.host != nil {
            return reference.url
        }
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else { return nil }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let referencePath = reference.percentEncodedPath
        components.percentEncodedPath = referencePath.hasPrefix("/")
            ? basePath + referencePath
            : basePath + "/" + referencePath
        components.percentEncodedQuery = reference.percentEncodedQuery
        components.fragment = nil
        return components.url
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

    /// `probe` marks a request whose failure is an answer, not a fault: an
    /// optional plugin route, a newer-server endpoint. It is still thrown
    /// to the caller but never reported as an incident.
    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], probe: Bool = false) async throws -> T {
        try await send(request(for: url(path: path, query: query), method: "GET", probe: probe))
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
        timeout: TimeInterval? = nil,
        maximumBytes: Int? = nil
    ) async throws -> Data {
        try await data(for: request(
            for: url(pathComponents: pathComponents, query: query),
            method: "GET",
            timeout: timeout
        ), maximumBytes: maximumBytes)
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
        /// Failures are expected and go unreported; see `get(_:query:probe:)`.
        var probe = false
    }

    private func request(
        for url: URL,
        method: String,
        body: Data? = nil,
        timeout: TimeInterval? = nil,
        authenticated: Bool = true,
        probe: Bool = false
    ) -> PreparedRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        // Never answer an API call from the HTTP cache: these responses carry
        // per-user state (resume points, played flags) that the app has just
        // changed with a report, and a cached copy is exactly the position
        // from before.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader(token: authenticated ? accessToken : nil), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return PreparedRequest(request: request, session: authenticated ? sessionIdentity : nil, probe: probe)
    }

    private func send<T: Decodable>(_ request: PreparedRequest) async throws -> T {
        let data = try await data(for: request)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            if !request.probe {
                APIDiagnostics.decodeFailed(error, request: request.request, serverURL: serverURL, client: "jellyfin")
            }
            throw error
        }
    }

    private func data(for request: PreparedRequest, maximumBytes: Int? = nil) async throws -> Data {
        let data: Data
        let status: Int
        let startedAt = ProcessInfo.processInfo.systemUptime
        if let maximumBytes {
            do {
                data = try await downloads.data(for: request.request, limit: maximumBytes, content: .subtitle)
                status = 200
            } catch DownloadFailure.httpStatus(let code, let body) {
                data = body
                status = code
            } catch {
                if let identity = request.session, identity != sessionIdentity { throw CancellationError() }
                if !request.probe {
                    APIDiagnostics.transportFailed(error, request: request.request, serverURL: serverURL, client: "jellyfin", startedAt: startedAt)
                }
                throw error
            }
        } else {
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request.request)
            } catch {
                if let identity = request.session, identity != sessionIdentity { throw CancellationError() }
                if !request.probe {
                    APIDiagnostics.transportFailed(error, request: request.request, serverURL: serverURL, client: "jellyfin", startedAt: startedAt)
                }
                throw error
            }
            guard let http = response as? HTTPURLResponse else { throw JellyfinError.server(status: 0) }
            status = http.statusCode
        }
        // A response belongs to the session captured before suspension. Even
        // a successful old response must not update the new account's screen.
        if let identity = request.session, identity != sessionIdentity { throw CancellationError() }
        switch status {
        case 200...299:
            return data
        case 401:
            if let identity = request.session {
                APIDiagnostics.statusFailed(status, request: request.request, serverURL: serverURL, client: "jellyfin", startedAt: startedAt)
                clearSession()
                onSessionExpired?(identity)
                throw JellyfinError.sessionExpired
            }
            throw JellyfinError.unauthorized
        default:
            if !request.probe {
                APIDiagnostics.statusFailed(status, request: request.request, serverURL: serverURL, client: "jellyfin", startedAt: startedAt)
            }
            throw JellyfinError.server(
                status: status,
                message: Self.serverMessage(from: data)
            )
        }
    }

    /// Pulls a human sentence out of an error body. Jellyfin answers with
    /// problem-details JSON, plain text, or an HTML page depending on where
    /// the failure happened; only the first two say anything worth showing.
    nonisolated static func serverMessage(from data: Data) -> String? {
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

    private nonisolated static func condensed(_ value: String) -> String? {
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
    /// is how Seerr can be signed into without a password.
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

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
    /// `message` is the server's body text, which often holds the real
    /// reason behind a 500 (an exhausted provider quota, say).
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
/// Jellyfin JSON is PascalCase; the decoder and encoder convert key casing,
/// so models never add CodingKeys for casing.
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
    /// Policy flags, resolved once per session from sign-in or, for a
    /// restored token, from the first `Users/Me`.
    private var subtitleManagementAllowed: Bool?
    private var contentDownloadingAllowed: Bool?
    private var videoTranscodingAllowed: Bool?
    /// The in-flight `Users/Me` fetch behind `refreshPolicy()`, so a screen
    /// warming several flags in a row shares one request.
    private struct PolicyFetch {
        let id: UUID
        let identity: SessionIdentity?
        let task: Task<UserDto?, Never>
    }
    private var policyFetch: PolicyFetch?

    /// For view code that must answer synchronously, e.g. a menu body. `nil`
    /// until resolved; a `.task` should call `canDownloadContent()` to warm it.
    var cachedContentDownloadingAllowed: Bool? { contentDownloadingAllowed }
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
        // API calls bypass the URL cache; see `request(for:)`.
        config.urlCache = nil
        session = URLSession(configuration: config, delegate: ServerHeaderRedirectGuard.shared, delegateQueue: nil)
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

    /// An independent copy for work that may outlive an account change.
    func sessionSnapshot() -> JellyfinClient {
        let copy = JellyfinClient(deviceId: deviceId, sessionConfiguration: session.configuration)
        if let serverURL { copy.configure(serverURL: serverURL) }
        if let accessToken, let userId { copy.activateSession(token: accessToken, userId: userId) }
        return copy
    }

    /// One `Users/Me` fetch that resolves subtitle, download and transcode
    /// permissions together and caches all three, so a caller warming
    /// several in a row sends one request instead of one per flag.
    /// Concurrent callers join the same in-flight fetch.
    ///
    /// Returns the fetched user, or nil when the server didn't answer (the
    /// caller falls back to whatever it has cached). Throws
    /// `CancellationError` when this session stopped being current while
    /// the request was in flight; a caller must not apply that answer.
    private func refreshPolicy() async throws -> UserDto? {
        let fetch: PolicyFetch
        // Only join a fetch started for the still-current session; one
        // left over from an account switch answers the wrong account.
        if let policyFetch, policyFetch.identity == sessionIdentity {
            fetch = policyFetch
        } else {
            let identity = sessionIdentity
            let id = UUID()
            let task = Task<UserDto?, Never> {
                let user = try? await self.currentUser()
                // A newer fetch may already have replaced this one.
                if self.policyFetch?.id == id { self.policyFetch = nil }
                return user
            }
            fetch = PolicyFetch(id: id, identity: identity, task: task)
            policyFetch = fetch
        }
        let user = await fetch.task.value
        guard fetch.identity == sessionIdentity, !Task.isCancelled else { throw CancellationError() }
        guard let user else { return nil }
        subtitleManagementAllowed = user.policy?.allowsSubtitleManagement ?? true
        if user.policy?.isAdministrator == true {
            contentDownloadingAllowed = true
            videoTranscodingAllowed = true
        } else {
            if let allowed = user.policy?.enableContentDownloading {
                contentDownloadingAllowed = allowed
            }
            if let allowed = user.policy?.enableVideoPlaybackTranscoding {
                videoTranscodingAllowed = allowed
            }
        }
        return user
    }

    /// Whether this account may use the remote-subtitle endpoints (403
    /// otherwise). An unreachable server answers `true`: a network problem
    /// must not read as a permissions problem.
    func canManageSubtitles() async -> Bool {
        if let subtitleManagementAllowed { return subtitleManagementAllowed }
        guard let user = try? await refreshPolicy() else { return true }
        return user.policy?.allowsSubtitleManagement ?? true
    }

    /// Re-asks the server, for a flag changed after sign-in. nil when
    /// unreachable, so Settings can say "couldn't check".
    func refreshSubtitlePermission() async -> Bool? {
        guard let user = try? await refreshPolicy() else { return nil }
        return user.policy?.allowsSubtitleManagement ?? true
    }

    /// Whether the account may download. Unlike subtitles, unknown means no.
    /// Administrators always pass.
    func canDownloadContent() async -> Bool {
        if let contentDownloadingAllowed { return contentDownloadingAllowed }
        return await refreshContentDownloadingPermission() ?? false
    }

    /// Re-asks the server. When unreachable, returns the last known value
    /// (nil the first time) rather than flipping to no.
    @discardableResult
    func refreshContentDownloadingPermission() async -> Bool? {
        let user: UserDto?
        // Never hand an old session's caller the new account's policy.
        do { user = try await refreshPolicy() } catch { return nil }
        guard let user else { return contentDownloadingAllowed }
        if user.policy?.isAdministrator == true { return true }
        return user.policy?.enableContentDownloading ?? contentDownloadingAllowed
    }

    /// Whether the server will build a High/Standard transcoded download.
    /// Unknown means no; administrators always pass.
    func canTranscodeForDownload() async -> Bool {
        if let videoTranscodingAllowed { return videoTranscodingAllowed }
        return await refreshVideoTranscodingPermission() ?? false
    }

    /// Same contract as `refreshContentDownloadingPermission()`.
    @discardableResult
    func refreshVideoTranscodingPermission() async -> Bool? {
        let user: UserDto?
        do { user = try await refreshPolicy() } catch { return nil }
        guard let user else { return videoTranscodingAllowed }
        if user.policy?.isAdministrator == true { return true }
        return user.policy?.enableVideoPlaybackTranscoding ?? videoTranscodingAllowed
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
            queryNames: ["apikey", "api_key"],
            additionalHeaders: ServerHeaderStore.shared.fields(for: serverURL)
        )
    }

    // MARK: - Requests

    func requireUserId() throws -> String {
        guard let userId else { throw JellyfinError.notConfigured }
        return userId
    }

    /// Resolves a route from a response body (`TranscodingUrl`, subtitle
    /// `DeliveryUrl`) against the server, keeping a reverse-proxy base path
    /// like `https://host/jellyfin`. Do not use `URL(string:relativeTo:)`:
    /// it drops that path. Absolute references are returned as given.
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

    /// Encodes each component on its own. Opaque ids (subtitle-provider ids)
    /// can contain `/`, `?`, `%` or `#`, which interpolation would break.
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

    /// `probe`: failure is an answer (optional plugin, newer endpoint). It
    /// still throws but is never reported as an incident.
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
        // Never answer an API call from the HTTP cache: a cached copy holds
        // resume points and played flags from before the last report.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let timeout { request.timeoutInterval = timeout }
        request.setValue(authorizationHeader(token: authenticated ? accessToken : nil), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        ServerHeaderStore.shared.apply(to: &request)
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

    /// A transport failure (not an HTTP status): a stale session throws
    /// `CancellationError` instead, and everything else is reported once.
    private func throwTransportFailure(_ error: Error, request: PreparedRequest, startedAt: TimeInterval) throws -> Never {
        if let identity = request.session, identity != sessionIdentity { throw CancellationError() }
        if !request.probe {
            APIDiagnostics.transportFailed(error, request: request.request, serverURL: serverURL, client: "jellyfin", startedAt: startedAt)
        }
        throw error
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
                try throwTransportFailure(error, request: request, startedAt: startedAt)
            }
        } else {
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request.request)
            } catch {
                try throwTransportFailure(error, request: request, startedAt: startedAt)
            }
            guard let http = response as? HTTPURLResponse else { throw JellyfinError.server(status: 0) }
            status = http.statusCode
        }
        // Even a successful response from an old session must not reach the
        // new account's screen.
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

    /// A readable sentence from an error body: problem-details JSON or plain
    /// text. HTML pages are ignored.
    nonisolated static func serverMessage(from data: Data) -> String? {
        ServerErrorMessage.from(data)
    }

    // MARK: - Server probe (pre-auth, arbitrary URL)

    private nonisolated static let serverProbeSession: URLSession = UncachedSession.make(
        waitsForConnectivity: true,
        timeoutIntervalForResource: 15
    )

    /// The profile picker's status dot: a quick, unauthenticated answer or
    /// none. Never waits for connectivity, unlike `fetchPublicInfo`.
    private nonisolated static let reachabilitySession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 4
        return URLSession(configuration: configuration, delegate: ServerHeaderRedirectGuard.shared, delegateQueue: nil)
    }()

    nonisolated static func isReachable(_ serverURL: URL) async -> Bool {
        let request = URLRequest(url: serverURL.appending(path: "System/Info/Public")).withServerHeaders()
        guard let (_, response) = try? await reachabilitySession.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// The profile picker's "watching" line: a profile's most recent resume
    /// item, read with that profile's own token. Kept off the active session,
    /// so a rejected token never counts as this session expiring, and as
    /// quick as the status dot: the picker never waits on it.
    private static let peekTimeout: TimeInterval = 4

    func peekResume(serverURL: URL, userId: String, token: String) async -> MediaItem? {
        guard var components = URLComponents(
            url: serverURL.appending(path: "Users/\(userId)/Items/Resume"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "MediaTypes", value: "Video"),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.peekTimeout
        request.setValue(authorizationHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        ServerHeaderStore.shared.apply(to: &request)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let page = try? Self.decoder.decode(ItemsPage.self, from: data) else { return nil }
        return page.items.first
    }

    nonisolated static func fetchPublicInfo(at serverURL: URL) async throws -> PublicSystemInfo {
        var request = URLRequest(url: serverURL.appending(path: "System/Info/Public")).withServerHeaders()
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

    /// Approves a Quick Connect code as the signed-in user. Lagoon uses it
    /// to approve Jellyseerr's code, signing into Seerr without a password.
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

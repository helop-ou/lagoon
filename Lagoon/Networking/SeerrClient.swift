import Foundation

enum SeerrError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidResponse
    case server(Int, String)
    case unauthenticated
    case quickConnectUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "Enter a valid Seerr or Jellyseerr server address."
        case .invalidResponse:
            "The server returned an unreadable response."
        case .server(_, let message):
            message
        case .unauthenticated:
            "Connect this Lagoon account to Seerr to continue."
        case .quickConnectUnavailable:
            "Quick Connect is turned off on this Jellyfin server, so Lagoon can't sign in to Seerr for you. Sign in below instead."
        }
    }
}

/// A separate HTTP boundary for Seerr. It owns only an opaque per-user
/// session cookie; Jellyfin credentials and Seerr's global API key never
/// enter this client.
final class SeerrClient {
    private(set) var serverURL: URL?
    private(set) var sessionCookie: String?

    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var configurationGeneration = 0

    /// Its own session rather than `.shared`, so no Seerr response can be
    /// stored in — or answered from — the process-wide URL cache. `JellyfinClient`
    /// does the same for the same reason (HEL-132). Tests pass their own.
    init(session: URLSession? = nil, requestTimeout: TimeInterval = 20) {
        self.session = session ?? Self.uncachedSession()
        self.requestTimeout = requestTimeout
        decoder = JSONDecoder()
        encoder = JSONEncoder()
    }

    private nonisolated static func uncachedSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func configure(serverURL: URL) {
        configurationGeneration += 1
        self.serverURL = Self.normalizedServerURL(serverURL)
    }

    func clear() {
        configurationGeneration += 1
        serverURL = nil
        sessionCookie = nil
    }

    func setSessionCookie(_ cookie: String?) {
        sessionCookie = cookie
    }

    // MARK: - Server and authentication

    func status() async throws -> SeerrServerStatus {
        try await get("status", authenticated: false)
    }

    func publicSettings() async throws -> SeerrPublicSettings {
        try await get("settings/public", authenticated: false)
    }

    func currentUser() async throws -> SeerrUser {
        try await get("auth/me")
    }

    func initiateQuickConnect() async throws -> SeerrQuickConnect {
        try await post("auth/jellyfin/quickconnect/initiate", authenticated: false)
    }

    func quickConnectState(secret: String) async throws -> SeerrQuickConnectState {
        try await get(
            "auth/jellyfin/quickconnect/check",
            query: [URLQueryItem(name: "secret", value: secret)],
            authenticated: false
        )
    }

    func authenticateQuickConnect(secret: String) async throws -> SeerrUser {
        try await post(
            "auth/jellyfin/quickconnect/authenticate",
            body: QuickConnectAuthentication(secret: secret),
            authenticated: false
        )
    }

    func authenticateJellyfin(username: String, password: String) async throws -> SeerrUser {
        try await post(
            "auth/jellyfin",
            body: JellyfinAuthentication(username: username, password: password),
            authenticated: false
        )
    }

    func logout() async throws {
        try await postVoid("auth/logout")
        sessionCookie = nil
    }

    // MARK: - Discovery

    func trending(page: Int = 1, mediaType: SeerrMediaType? = nil) async throws -> SeerrDiscoverPage {
        var query = [URLQueryItem(name: "page", value: String(page))]
        if let mediaType {
            query.append(URLQueryItem(name: "mediaType", value: mediaType.rawValue))
        }
        return try await get("discover/trending", query: query)
    }

    func discover(_ mediaType: SeerrMediaType, page: Int = 1) async throws -> SeerrDiscoverPage {
        let path = mediaType == .movie ? "discover/movies" : "discover/tv"
        return try await get(path, query: [URLQueryItem(name: "page", value: String(page))])
    }

    func upcoming(_ mediaType: SeerrMediaType, page: Int = 1) async throws -> SeerrDiscoverPage {
        let path = mediaType == .movie ? "discover/movies/upcoming" : "discover/tv/upcoming"
        return try await get(path, query: [URLQueryItem(name: "page", value: String(page))])
    }

    /// The viewer's own watchlist. Named `PLEX_WATCHLIST` in the slider enum
    /// Jellyseerr inherited from Overseerr; on a Jellyfin server it is the
    /// local watchlist, and the route is the same either way.
    func watchlist(page: Int = 1) async throws -> SeerrDiscoverPage {
        try await get("discover/watchlist", query: [URLQueryItem(name: "page", value: String(page))])
    }

    func genres(_ mediaType: SeerrMediaType) async throws -> [SeerrGenre] {
        let path = mediaType == .movie ? "discover/genreslider/movie" : "discover/genreslider/tv"
        return try await get(path)
    }

    func discover(
        _ mediaType: SeerrMediaType,
        genreID: Int,
        page: Int = 1
    ) async throws -> SeerrDiscoverPage {
        let path = mediaType == .movie
            ? "discover/movies/genre/\(genreID)"
            : "discover/tv/genre/\(genreID)"
        return try await get(path, query: [URLQueryItem(name: "page", value: String(page))])
    }

    /// The rows the server owner arranged for their own Discover page. Only
    /// the type number and order come back for built-ins; the titles are the
    /// client's to supply.
    func discoverSliders() async throws -> [SeerrDiscoverSlider] {
        try await get("settings/discover")
    }

    func search(query term: String, page: Int = 1) async throws -> SeerrDiscoverPage {
        try await get("search", query: [
            URLQueryItem(name: "query", value: term),
            URLQueryItem(name: "page", value: String(page)),
        ])
    }

    func details(id: Int, mediaType: SeerrMediaType) async throws -> SeerrMediaDetails {
        switch mediaType {
        case .movie:
            return try await get("movie/\(id)")
        case .tv:
            return try await get("tv/\(id)")
        case .person:
            throw SeerrError.server(400, "People do not have requestable media details.")
        }
    }

    // MARK: - Requests

    func requests(
        take: Int = 20,
        skip: Int = 0,
        filter: SeerrRequestFilter = .all,
        mediaType: SeerrMediaType? = nil,
        requestedBy: Int? = nil
    ) async throws -> SeerrRequestsPage {
        var query = [
            URLQueryItem(name: "take", value: String(take)),
            URLQueryItem(name: "skip", value: String(skip)),
            URLQueryItem(name: "filter", value: filter.rawValue),
            URLQueryItem(name: "sort", value: "modified"),
            URLQueryItem(name: "sortDirection", value: "desc"),
        ]
        if let mediaType {
            query.append(URLQueryItem(name: "mediaType", value: mediaType.rawValue))
        }
        if let requestedBy {
            query.append(URLQueryItem(name: "requestedBy", value: String(requestedBy)))
        }
        return try await get("request", query: query)
    }

    func createRequest(_ request: SeerrCreateRequest) async throws -> SeerrMediaRequest {
        try await post("request", body: request)
    }

    func request(id: Int) async throws -> SeerrMediaRequest {
        try await get("request/\(id)")
    }

    func setRequestStatus(id: Int, approved: Bool) async throws -> SeerrMediaRequest {
        try await post("request/\(id)/\(approved ? "approve" : "decline")")
    }

    func deleteRequest(id: Int) async throws {
        try await deleteVoid("request/\(id)")
    }

    // MARK: - Artwork

    /// TMDB serves a fixed set of widths and answers 400 for anything else —
    /// `w720` is not a rendition, it is a broken link. The requested width is
    /// therefore snapped up to the next size TMDB actually has, so a caller
    /// can ask for the width its layout needs without knowing the list
    /// (HEL-114).
    nonisolated static let tmdbImageWidths = [92, 154, 185, 342, 500, 780, 1280]

    nonisolated static func imageURL(path: String?, width: Int) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let size = tmdbImageWidths.first { $0 >= width }.map { "w\($0)" } ?? "original"
        return URL(string: "https://image.tmdb.org/t/p/\(size)\(normalizedPath)")
    }

    // MARK: - HTTP

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> T {
        try await send(path: path, method: "GET", query: query, authenticated: authenticated)
    }

    private func post<T: Decodable>(
        _ path: String,
        authenticated: Bool = true
    ) async throws -> T {
        try await send(path: path, method: "POST", authenticated: authenticated)
    }

    private func post<T: Decodable, Body: Encodable>(
        _ path: String,
        body: Body,
        authenticated: Bool = true
    ) async throws -> T {
        try await send(
            path: path,
            method: "POST",
            body: try encoder.encode(body),
            authenticated: authenticated
        )
    }

    // MARK: - Radarr / Sonarr

    /// The configured servers for a media type. Readable without admin — the
    /// request detail uses it to name the profile a request was made against
    /// (HEL-118).
    func services(_ mediaType: SeerrMediaType) async throws -> [SeerrService] {
        try await get("service/\(mediaType == .movie ? "radarr" : "sonarr")")
    }

    /// One server's quality profiles. `MediaRequest` carries only a
    /// `profileId`; the names live here.
    func qualityProfiles(
        _ mediaType: SeerrMediaType,
        serverID: Int
    ) async throws -> [SeerrQualityProfile] {
        let details: SeerrServiceDetails = try await get(
            "service/\(mediaType == .movie ? "radarr" : "sonarr")/\(serverID)"
        )
        return details.profiles
    }

    /// Lifts an administrator's block on a title. Jellyseerr removes the
    /// media row along with the blocklist entry, so the title goes back to
    /// being simply not-requested and can be asked for again. `mediaType` is
    /// required — the route answers 400 without it.
    func removeFromBlocklist(tmdbID: Int, mediaType: SeerrMediaType) async throws {
        _ = try await data(
            path: "blocklist/\(tmdbID)",
            method: "DELETE",
            query: [URLQueryItem(name: "mediaType", value: mediaType.rawValue)],
            authenticated: true
        )
    }

    private func postVoid(_ path: String) async throws {
        _ = try await data(path: path, method: "POST", authenticated: true)
    }

    private func deleteVoid(_ path: String) async throws {
        _ = try await data(path: path, method: "DELETE", authenticated: true)
    }

    private func send<T: Decodable>(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        authenticated: Bool
    ) async throws -> T {
        let payload = try await data(
            path: path,
            method: method,
            query: query,
            body: body,
            authenticated: authenticated
        )
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw SeerrError.invalidResponse
        }
    }

    private func data(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        authenticated: Bool
    ) async throws -> Data {
        guard let serverURL else { throw SeerrError.invalidServerURL }
        let requestGeneration = configurationGeneration
        var components = URLComponents(
            url: serverURL.appending(path: "api/v1").appending(path: path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url else { throw SeerrError.invalidServerURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        // Never answer a Seerr call from an HTTP cache. The live-refresh loops
        // poll constant, cache-keyable URLs (`request/{id}`, `movie/{tmdbId}`)
        // for the express purpose of seeing state the server has just changed,
        // so any freshness lifetime Jellyseerr or a reverse proxy in front of
        // it emits would make them silently observe nothing (HEL-132, HEL-136).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let sessionCookie else { throw SeerrError.unauthenticated }
            request.setValue("connect.sid=\(sessionCookie)", forHTTPHeaderField: "Cookie")
        }

        let responsePayload = try await response(for: request)
        let data = responsePayload.data
        let response = responsePayload.response
        // An account switch clears/reconfigures this shared client. A late
        // response from the previous account must never install its cookie
        // or update the new account's UI state.
        guard configurationGeneration == requestGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw SeerrError.invalidResponse }
        captureSessionCookie(from: http, url: url)
        guard (200..<300).contains(http.statusCode) else {
            if authenticated && http.statusCode == 401 {
                throw SeerrError.unauthenticated
            }
            let message = (try? decoder.decode(ErrorPayload.self, from: data).displayMessage)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SeerrError.server(http.statusCode, message)
        }
        return data
    }

    /// `URLRequest.timeoutInterval` is an inactivity timeout, not a hard
    /// deadline. A server that slowly dribbles response bytes can therefore
    /// keep a discovery request alive indefinitely and strand the UI on an
    /// activity indicator. Race the transport against an absolute deadline so
    /// every Seerr screen can reach its existing error-and-retry state.
    private func response(for request: URLRequest) async throws -> ResponsePayload {
        try await withThrowingTaskGroup(of: ResponsePayload.self) { group in
            group.addTask { [session] in
                let (data, response) = try await session.data(for: request)
                return ResponsePayload(data: data, response: response)
            }
            group.addTask { [requestTimeout] in
                try await Task.sleep(for: .seconds(requestTimeout))
                throw URLError(.timedOut)
            }

            guard let first = try await group.next() else {
                throw SeerrError.invalidResponse
            }
            group.cancelAll()
            return first
        }
    }

    private func captureSessionCookie(from response: HTTPURLResponse, url: URL) {
        let fields = response.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String, let value = entry.value as? String else { return }
            result[key] = value
        }
        guard let cookie = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
            .first(where: { $0.name == "connect.sid" }) else { return }
        sessionCookie = cookie.value
    }

    nonisolated static func candidateURLs(for input: String) -> [URL] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("://") {
            return URL(string: trimmed).map { [normalizedServerURL($0)] } ?? []
        }

        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let hasPort = host.split(separator: ":").count == 2
        let looksLocal = host.hasSuffix(".local")
            || host.split(separator: ":").first.map { $0.allSatisfy { $0.isNumber || $0 == "." } } == true
        var candidates = looksLocal
            ? ["http://\(trimmed)", "https://\(trimmed)"]
            : ["https://\(trimmed)", "http://\(trimmed)"]
        if !hasPort { candidates.append("http://\(trimmed):5055") }
        return candidates.compactMap(URL.init(string:)).map(normalizedServerURL)
    }

    private nonisolated static func normalizedServerURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        if path.hasSuffix("/api/v1") {
            path.removeLast("/api/v1".count)
        }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components?.path = path == "/" ? "" : path
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }
}

private struct ResponsePayload: @unchecked Sendable {
    let data: Data
    let response: URLResponse
}

private nonisolated struct QuickConnectAuthentication: Encodable {
    let secret: String
}

private nonisolated struct JellyfinAuthentication: Encodable {
    let username: String
    let password: String
}

private nonisolated struct ErrorPayload: Decodable {
    let message: String?
    let error: String?

    var displayMessage: String { message ?? error ?? "The Seerr request failed." }
}

import Foundation

nonisolated enum OpenSubtitlesError: LocalizedError, Equatable {
    case notConfigured
    case unauthorized
    case quotaExhausted(resetTime: String?)
    case rateLimited
    case linkExpired
    case invalidResponse
    case offline
    case timedOut
    case server(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Lagoon has no OpenSubtitles API key, so it can't search the provider directly."
        case .unauthorized:
            "The OpenSubtitles sign-in was rejected. Check the username and password."
        case .quotaExhausted(let resetTime):
            if let resetTime {
                "The OpenSubtitles download limit for today is used up. It resets in \(resetTime)."
            } else {
                "The OpenSubtitles download limit for today is used up."
            }
        case .rateLimited:
            "OpenSubtitles is rate-limiting requests right now. Try again in a few minutes."
        case .linkExpired:
            "That OpenSubtitles download link expired before Lagoon could use it."
        case .invalidResponse:
            "OpenSubtitles returned a response Lagoon couldn't read."
        case .offline:
            "Lagoon couldn't reach OpenSubtitles."
        case .timedOut:
            "OpenSubtitles didn't respond in time."
        case .server(let status):
            "OpenSubtitles returned an error (\(status))."
        }
    }

    /// Only the quota case is worth surfacing as an invitation to sign in:
    /// an account raises the daily allowance, nothing else about it helps.
    var invitesSignIn: Bool {
        if case .quotaExhausted = self { return true }
        return false
    }

    static func classify(_ error: Error) -> OpenSubtitlesError {
        if let known = error as? OpenSubtitlesError { return known }
        guard let url = error as? URLError else { return .invalidResponse }
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
}

/// One subtitle the provider is offering.
nonisolated struct OpenSubtitlesResult: Equatable, Sendable {
    let fileID: Int
    let releaseName: String?
    let language: String?
    let uploader: String?
    let downloadCount: Int?
    let rating: Double?
    let isHashMatch: Bool
    let isHearingImpaired: Bool
    /// OpenSubtitles models "forced" as foreign-parts-only, and marks some
    /// hearing-impaired uploads that way too; both flags are needed to tell
    /// a genuinely forced track from a full one.
    let isForeignPartsOnly: Bool
    let isMachineTranslated: Bool
    let isAITranslated: Bool

    var isForced: Bool { isForeignPartsOnly && !isHearingImpaired }
}

/// What a search knows about the item being played.
nonisolated struct OpenSubtitlesQuery: Equatable, Sendable {
    var languages: [String]
    var movieHash: String?
    var imdbID: String?
    var tmdbID: String?
    var title: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var isEpisode: Bool

    /// A query with nothing to match on would return the provider's idea of
    /// popular subtitles rather than this movie's.
    var isSearchable: Bool {
        movieHash != nil || imdbID != nil || tmdbID != nil
            || !(title ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A separate HTTP boundary for OpenSubtitles, mirroring `SeerrClient`: it
/// owns an app API key and, optionally, one user token. No Jellyfin
/// credential ever enters this client, and nothing it holds is sent to
/// Jellyfin (HEL-92).
final class OpenSubtitlesClient {
    static let defaultHost = "api.opensubtitles.com"
    /// OpenSubtitles requires a descriptive User-Agent and rejects defaults.
    static let userAgent = "Lagoon v1.0"

    private(set) var apiKey: String?
    private(set) var token: String?
    private(set) var accountName: String?
    private(set) var allowedDownloads: Int?
    private(set) var remainingDownloads: Int?
    /// A signed-in VIP is redirected to their own host by the login response.
    private(set) var host: String = OpenSubtitlesClient.defaultHost

    private let session: URLSession
    private let requestTimeout: TimeInterval
    private let decoder: JSONDecoder

    init(session: URLSession = .shared, requestTimeout: TimeInterval = 30) {
        self.session = session
        self.requestTimeout = requestTimeout
        decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    var isConfigured: Bool { !(apiKey ?? "").isEmpty }
    var isSignedIn: Bool { token != nil }

    func configure(apiKey: String?) {
        let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    func restoreSession(token: String?, accountName: String?) {
        self.token = token
        self.accountName = accountName
    }

    func signOut() {
        token = nil
        accountName = nil
        allowedDownloads = nil
        remainingDownloads = nil
        host = Self.defaultHost
    }

    // MARK: - Authentication

    nonisolated private struct LoginRequest: Encodable {
        let username: String
        let password: String
    }

    nonisolated private struct LoginResponse: Decodable {
        struct User: Decodable {
            let allowedDownloads: Int?
            let level: String?
        }
        let token: String
        let baseUrl: String?
        let user: User?
    }

    @discardableResult
    func signIn(username: String, password: String) async throws -> String {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        let body = try JSONEncoder().encode(LoginRequest(username: username, password: password))
        let data = try await send(
            path: "login",
            method: "POST",
            body: body,
            authenticated: false
        )
        guard let response = try? decoder.decode(LoginResponse.self, from: data) else {
            throw OpenSubtitlesError.invalidResponse
        }
        token = response.token
        accountName = username
        allowedDownloads = response.user?.allowedDownloads
        if let base = response.baseUrl, !base.isEmpty {
            // The value is a bare hostname, not a URL.
            host = base.replacingOccurrences(of: "https://", with: "")
                .replacingOccurrences(of: "http://", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return username
    }

    // MARK: - Search

    nonisolated private struct SearchResponse: Decodable {
        struct Item: Decodable {
            struct Attributes: Decodable {
                struct File: Decodable {
                    let fileId: Int?
                    let fileName: String?
                }
                struct Uploader: Decodable {
                    let name: String?
                }
                let language: String?
                let release: String?
                let downloadCount: Int?
                let ratings: Double?
                let hearingImpaired: Bool?
                let foreignPartsOnly: Bool?
                let machineTranslated: Bool?
                let aiTranslated: Bool?
                let moviehashMatch: Bool?
                let uploader: Uploader?
                let files: [File]?
            }
            let attributes: Attributes?
        }
        let data: [Item]?
    }

    func search(_ query: OpenSubtitlesQuery) async throws -> [OpenSubtitlesResult] {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        guard query.isSearchable else { return [] }
        let data = try await send(
            path: "subtitles",
            method: "GET",
            query: Self.queryItems(for: query)
        )
        guard let response = try? decoder.decode(SearchResponse.self, from: data) else {
            throw OpenSubtitlesError.invalidResponse
        }
        return (response.data ?? []).compactMap { item in
            guard let attributes = item.attributes,
                  let fileID = attributes.files?.first(where: { $0.fileId != nil })?.fileId else {
                return nil
            }
            return OpenSubtitlesResult(
                fileID: fileID,
                releaseName: attributes.release,
                language: attributes.language,
                uploader: attributes.uploader?.name,
                downloadCount: attributes.downloadCount,
                rating: attributes.ratings,
                isHashMatch: attributes.moviehashMatch ?? false,
                isHearingImpaired: attributes.hearingImpaired ?? false,
                isForeignPartsOnly: attributes.foreignPartsOnly ?? false,
                isMachineTranslated: attributes.machineTranslated ?? false,
                isAITranslated: attributes.aiTranslated ?? false
            )
        }
    }

    /// OpenSubtitles asks that parameters arrive sorted and lowercased so its
    /// cache is not split and the request is not redirected.
    static func queryItems(for query: OpenSubtitlesQuery) -> [URLQueryItem] {
        var items: [URLQueryItem] = []
        let languages = query.languages
            .compactMap { JellyfinSubtitleLanguageCode.twoLetter(for: $0) }
            .reduce(into: [String]()) { result, code in
                if !result.contains(code) { result.append(code) }
            }
        if !languages.isEmpty {
            items.append(URLQueryItem(name: "languages", value: languages.sorted().joined(separator: ",")))
        }
        if let hash = query.movieHash {
            items.append(URLQueryItem(name: "moviehash", value: hash))
        }
        if let imdb = Self.numericIdentifier(from: query.imdbID) {
            items.append(URLQueryItem(name: "imdb_id", value: imdb))
        }
        if let tmdb = Self.numericIdentifier(from: query.tmdbID) {
            items.append(URLQueryItem(name: "tmdb_id", value: tmdb))
        }
        // An id is a precise filter; adding a title alongside it can only
        // narrow the match on a spelling difference, so it is the fallback.
        if items.allSatisfy({ $0.name == "languages" || $0.name == "moviehash" }),
           let title = query.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            items.append(URLQueryItem(name: "query", value: title.lowercased()))
        }
        if query.isEpisode {
            if let season = query.seasonNumber {
                items.append(URLQueryItem(name: "season_number", value: String(season)))
            }
            if let episode = query.episodeNumber {
                items.append(URLQueryItem(name: "episode_number", value: String(episode)))
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    /// Jellyfin stores IMDb ids as "tt0133093"; the API wants the digits.
    static func numericIdentifier(from raw: String?) -> String? {
        guard let raw else { return nil }
        let digits = raw.filter(\.isNumber)
        return digits.isEmpty ? nil : digits
    }

    // MARK: - Download

    nonisolated private struct DownloadRequest: Encodable {
        let fileId: Int
        /// The provider converts on its side, which is what keeps ASS/SSA and
        /// other authored formats out of Lagoon's parser.
        let subFormat: String

        enum CodingKeys: String, CodingKey {
            case fileId = "file_id"
            case subFormat = "sub_format"
        }
    }

    nonisolated private struct DownloadResponse: Decodable {
        let link: String?
        let fileName: String?
        let requests: Int?
        let remaining: Int?
        let resetTime: String?
    }

    /// Two steps by design: the provider issues a short-lived link, and the
    /// bytes come from a plain GET that must not carry the API credentials.
    func download(fileID: Int) async throws -> Data {
        guard isConfigured else { throw OpenSubtitlesError.notConfigured }
        let body = try JSONEncoder().encode(
            DownloadRequest(fileId: fileID, subFormat: "srt")
        )
        let data = try await send(path: "download", method: "POST", body: body)
        guard let response = try? decoder.decode(DownloadResponse.self, from: data),
              let link = response.link,
              let url = URL(string: link) else {
            throw OpenSubtitlesError.invalidResponse
        }
        remainingDownloads = response.remaining

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (payload, fileResponse) = try await session.data(for: request)
        guard let http = fileResponse as? HTTPURLResponse else {
            throw OpenSubtitlesError.invalidResponse
        }
        if http.statusCode == 410 { throw OpenSubtitlesError.linkExpired }
        guard (200...299).contains(http.statusCode) else {
            throw OpenSubtitlesError.server(http.statusCode)
        }
        guard !payload.isEmpty else { throw OpenSubtitlesError.invalidResponse }
        return payload
    }

    // MARK: - Transport

    nonisolated private struct QuotaBody: Decodable {
        let requests: Int?
        let remaining: Int?
        let resetTime: String?
    }

    private func send(
        path: String,
        method: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        authenticated: Bool = true
    ) async throws -> Data {
        guard let apiKey else { throw OpenSubtitlesError.notConfigured }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/api/v1/" + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw OpenSubtitlesError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubtitlesError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return data
        case 401:
            // The token expired; drop it so the next call is anonymous rather
            // than repeatedly rejected.
            token = nil
            accountName = nil
            throw OpenSubtitlesError.unauthorized
        case 403:
            throw OpenSubtitlesError.notConfigured
        case 406:
            let quota = try? decoder.decode(QuotaBody.self, from: data)
            remainingDownloads = quota?.remaining ?? 0
            throw OpenSubtitlesError.quotaExhausted(resetTime: quota?.resetTime)
        case 410:
            throw OpenSubtitlesError.linkExpired
        case 429:
            throw OpenSubtitlesError.rateLimited
        default:
            throw OpenSubtitlesError.server(http.statusCode)
        }
    }
}

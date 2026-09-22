import Foundation

// Seerr has its own model layer: its numeric ids are TMDB ids, not Jellyfin
// item ids, and mixing the two breaks navigation and availability state.

nonisolated struct SeerrServerStatus: Decodable, Equatable {
    let version: String
    let commitTag: String?
}

nonisolated struct SeerrPublicSettings: Decodable, Equatable {
    let initialized: Bool
    let applicationTitle: String?
    let mediaServerLogin: Bool?
    let jellyfinExternalHost: String?
    let mediaServerType: Int?
    let partialRequestsEnabled: Bool?
    let enableSpecialEpisodes: Bool?
    let movie4kEnabled: Bool?
    let series4kEnabled: Bool?
    let locale: String?
}

nonisolated struct SeerrUser: Decodable, Hashable, Identifiable {
    let id: Int
    let email: String?
    let username: String?
    let displayName: String?
    let jellyfinUsername: String?
    let avatar: String?
    let permissions: Int

    var name: String {
        displayName ?? username ?? jellyfinUsername ?? email ?? "Seerr User"
    }

    func hasPermission(_ permission: SeerrPermission) -> Bool {
        permissions & SeerrPermission.admin.rawValue != 0
            || permissions & permission.rawValue != 0
    }

    var canManageRequests: Bool { hasPermission(.manageRequests) }
    var canManageBlocklist: Bool { hasPermission(.manageBlocklist) }
    var canViewAllRequests: Bool {
        hasPermission(.manageRequests) || hasPermission(.requestView)
    }

    func canRequest(_ type: SeerrMediaType) -> Bool {
        if hasPermission(.request) { return true }
        switch type {
        case .movie:
            return hasPermission(.requestMovie)
        case .tv:
            return hasPermission(.requestTV)
        case .person:
            return false
        }
    }
}

/// Seerr's public permission bit flags. Admin overrides all of them, as in
/// Seerr.
nonisolated enum SeerrPermission: Int, Hashable {
    case admin = 2
    case manageRequests = 16
    case request = 32
    case autoApprove = 128
    case autoApproveMovie = 256
    case autoApproveTV = 512
    case requestAdvanced = 8192
    case requestView = 16384
    case requestMovie = 262_144
    case requestTV = 524_288
    case manageBlocklist = 268_435_456
    case viewBlocklist = 1_073_741_824
}

/// The three types Lagoon can request and route. Search also returns other
/// types (`collection`), so DTOs decode this with `try?` into an optional: an
/// unknown type leaves that result typeless and never fails the page.
nonisolated enum SeerrMediaType: String, Codable, Hashable, CaseIterable, Identifiable {
    case movie
    case tv
    case person

    var id: String { rawValue }
    var title: String {
        switch self {
        case .movie: "Movie"
        case .tv: "Show"
        case .person: "Person"
        }
    }
}

/// Jellyseerr's `MediaStatus`. The numbers are the contract, so they are
/// spelled out: 6 is blocklisted, 7 is deleted.
nonisolated enum SeerrAvailabilityStatus: Int, Hashable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    case blocklisted = 6
    case deleted = 7

    init(apiValue: Int?) {
        self = apiValue.flatMap(Self.init(rawValue:)) ?? .unknown
    }

    var title: String {
        switch self {
        case .unknown: "Not Requested"
        case .pending: "Pending"
        case .processing: "Processing"
        case .partiallyAvailable: "Partially Available"
        case .available: "Available"
        case .blocklisted: "Blocked"
        // Gone from the library, so it can be requested again.
        case .deleted: "Not Requested"
        }
    }

    /// Deleted media can be requested again; the server refuses blocklisted
    /// media.
    var allowsRequesting: Bool {
        self == .unknown || self == .deleted
    }

    var isPlayable: Bool {
        self == .available || self == .partiallyAvailable
    }
}

/// Jellyseerr's `MediaRequestStatus`. An unrecognised value maps to
/// `.unknown`, never to `.pending`: guessing a state is how completed and
/// failed requests once showed "Pending Approval" forever.
nonisolated enum SeerrRequestStatus: Int, Hashable {
    case pending = 1
    case approved = 2
    case declined = 3
    case failed = 4
    case completed = 5
    case unknown = -1

    init(apiValue: Int) {
        self = Self(rawValue: apiValue) ?? .unknown
    }

    var title: String {
        switch self {
        case .pending: "Pending Approval"
        case .approved: "Approved"
        case .declined: "Declined"
        case .failed: "Failed"
        case .completed: "Completed"
        case .unknown: "Unknown"
        }
    }

    /// Approved and completed both mean yes; only the library says whether
    /// it has arrived.
    var isGranted: Bool {
        self == .approved || self == .completed
    }
}

/// How a status glyph animates while its row or button holds focus.
nonisolated enum SeerrStatusMotion: Hashable {
    case still
    case rotate
    case bounce
    /// For waiting rather than working.
    case pulse
}

/// Whether a viewer can watch a request yet: the request status until it is
/// approved, the media's availability after that.
nonisolated enum SeerrRequestProgress: Hashable {
    case pending
    case declined
    case failed
    case processing
    case partiallyAvailable
    case available
    /// Granted, arrived, and since removed from the library.
    case removed
    /// Granted, then blocked by an administrator.
    case blocked
    case unknown

    var title: String {
        switch self {
        case .pending: "Pending"
        case .declined: "Declined"
        case .failed: "Failed"
        case .processing: "Processing"
        case .partiallyAvailable: "Partly Available"
        case .available: "Available"
        case .removed: "Removed"
        case .blocked: "Blocked"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .declined: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        case .processing: "arrow.triangle.2.circlepath"
        case .partiallyAvailable: "circle.lefthalf.filled"
        case .available: "checkmark.circle"
        case .removed: "trash"
        case .blocked: "hand.raised"
        case .unknown: "questionmark.circle"
        }
    }

    /// Only states still in progress animate; a moving final state reads as
    /// an error.
    var motion: SeerrStatusMotion {
        switch self {
        case .pending: .pulse
        case .processing: .rotate
        case .declined, .failed, .partiallyAvailable, .available,
             .removed, .blocked, .unknown: .still
        }
    }

    static func resolve(
        request: SeerrRequestStatus,
        availability: SeerrAvailabilityStatus
    ) -> SeerrRequestProgress {
        switch request {
        case .pending: .pending
        case .declined: .declined
        case .failed: .failed
        case .unknown: .unknown
        case .approved, .completed:
            // Exhaustive on purpose, no `default:`: a new availability case
            // must fail to compile here so someone decides what it means.
            switch availability {
            case .available: .available
            case .partiallyAvailable: .partiallyAvailable
            // A completed request whose media was since removed.
            case .deleted: .removed
            case .blocklisted: .blocked
            // Granted, not in the library yet.
            case .unknown, .pending, .processing: .processing
            }
        }
    }
}

/// One entry in Radarr/Sonarr's queue, as Jellyseerr relays it on
/// `mediaInfo.downloadStatus`.
nonisolated struct SeerrDownloadItem: Decodable, Hashable, Identifiable {
    let downloadId: String
    let title: String
    /// Radarr/Sonarr's queue word ("downloading", "queued"). A string because
    /// they can add values.
    let status: String
    let size: Int64
    let sizeLeft: Int64
    let timeLeft: String?

    var id: String { downloadId }

    /// 0 when the size is unknown.
    var fractionComplete: Double {
        guard size > 0 else { return 0 }
        return min(1, max(0, Double(size - sizeLeft) / Double(size)))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadId = try container.decodeIfPresent(String.self, forKey: .downloadId) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        sizeLeft = try container.decodeIfPresent(Int64.self, forKey: .sizeLeft) ?? 0
        timeLeft = try container.decodeIfPresent(String.self, forKey: .timeLeft)
    }

    private enum CodingKeys: String, CodingKey {
        case downloadId, title, status, size, sizeLeft, timeLeft
    }
}

/// What the queue adds up to for one title.
///
/// Deduplicated by `downloadId`: Sonarr reports a season pack once per
/// episode, each row with the pack's full size, so summing rows overcounts.
nonisolated struct SeerrDownloadProgress: Hashable {
    let fraction: Double
    let downloadCount: Int
    let timeLeft: String?
    /// Downloaded but not yet in the library: Radarr/Sonarr is importing it.
    /// Without this a finished download looks stuck at 100%.
    let isImporting: Bool

    init?(items: [SeerrDownloadItem]) {
        var seen = Set<String>()
        let unique = items.filter { item in
            // Keep entries with no id: over-counting beats dropping them.
            guard !item.downloadId.isEmpty else { return true }
            return seen.insert(item.downloadId).inserted
        }
        guard !unique.isEmpty else { return nil }

        let totalSize = unique.reduce(Int64(0)) { $0 + $1.size }
        let totalLeft = unique.reduce(Int64(0)) { $0 + $1.sizeLeft }
        fraction = totalSize > 0
            ? min(1, max(0, Double(totalSize - totalLeft) / Double(totalSize)))
            : 0
        downloadCount = unique.count
        isImporting = unique.allSatisfy { $0.sizeLeft <= 0 }
        // Quote a running entry; finished ones report "00:00:00".
        timeLeft = unique
            .filter { $0.sizeLeft > 0 }
            .compactMap(\.timeLeft)
            .filter { !$0.isEmpty && $0 != "00:00:00" }
            .max()
    }

    var percentText: String {
        "\(Int((fraction * 100).rounded()))%"
    }

    var summary: String {
        if isImporting {
            return String(localized: "Downloaded, adding to your library")
        }
        if let timeLeft {
            return String(localized: "Downloading \(percentText) · \(timeLeft) left")
        }
        return String(localized: "Downloading \(percentText)")
    }
}

nonisolated struct SeerrDiscoverPage: Decodable, Equatable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [SeerrDiscoverResult]
}

nonisolated struct SeerrDiscoverResult: Decodable, Hashable, Identifiable {
    let id: Int
    let mediaType: SeerrMediaType?
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let voteAverage: Double?
    let mediaInfo: SeerrMediaInfo?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // `id` stays strict: it is the TMDB identity used for navigation and
        // dedup, and defaulted ids would collide.
        id = try container.decode(Int.self, forKey: .id)
        mediaType = try? container.decodeIfPresent(SeerrMediaType.self, forKey: .mediaType)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        originalTitle = try container.decodeIfPresent(String.self, forKey: .originalTitle)
        originalName = try container.decodeIfPresent(String.self, forKey: .originalName)
        overview = try container.decodeIfPresent(String.self, forKey: .overview)
        posterPath = try container.decodeIfPresent(String.self, forKey: .posterPath)
        backdropPath = try container.decodeIfPresent(String.self, forKey: .backdropPath)
        releaseDate = try container.decodeIfPresent(String.self, forKey: .releaseDate)
        firstAirDate = try container.decodeIfPresent(String.self, forKey: .firstAirDate)
        voteAverage = try container.decodeIfPresent(Double.self, forKey: .voteAverage)
        mediaInfo = try container.decodeIfPresent(SeerrMediaInfo.self, forKey: .mediaInfo)
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaType, title, name, originalTitle, originalName, overview
        case posterPath, backdropPath, releaseDate, firstAirDate, voteAverage, mediaInfo
    }

    var displayTitle: String { title ?? name ?? originalTitle ?? originalName ?? "Untitled" }
    var date: String? { releaseDate ?? firstAirDate }
    var year: String? { date.map { String($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 } }
}

nonisolated struct SeerrMediaDetails: Decodable, Hashable, Identifiable {
    let id: Int
    let title: String?
    let name: String?
    let originalTitle: String?
    let originalName: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let firstAirDate: String?
    let runtime: Int?
    let episodeRunTime: [Int]?
    let voteAverage: Double?
    let tagline: String?
    let genres: [SeerrGenre]?
    let seasons: [SeerrSeason]?
    let mediaInfo: SeerrMediaInfo?
    let credits: SeerrCredits?
    /// A movie's certifications per country.
    let releases: SeerrReleases?
    /// A show's certifications per country.
    let contentRatings: SeerrContentRatings?

    var displayTitle: String { title ?? name ?? originalTitle ?? originalName ?? "Untitled" }
    var date: String? { releaseDate ?? firstAirDate }
    var year: String? { date.map { String($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 } }

    /// The viewer's region's certification, else the US one (as Jellyfin
    /// falls back), else nil rather than an unfamiliar foreign label.
    func officialRating(region: String? = Locale.current.region?.identifier) -> String? {
        let byCountry: [(country: String, rating: String)]
        if let releases {
            byCountry = releases.results.flatMap { release in
                release.releaseDates
                    .compactMap(\.certification)
                    .filter { !$0.isEmpty }
                    .map { (release.iso3166_1, $0) }
            }
        } else if let contentRatings {
            byCountry = contentRatings.results
                .filter { !$0.rating.isEmpty }
                .map { ($0.iso3166_1, $0.rating) }
        } else {
            return nil
        }
        for country in [region, "US"].compactMap({ $0 }) {
            if let match = byCountry.first(where: { $0.country.caseInsensitiveCompare(country) == .orderedSame }) {
                return match.rating
            }
        }
        return nil
    }
}

nonisolated struct SeerrCredits: Decodable, Hashable {
    let cast: [SeerrCastMember]
    let crew: [SeerrCrewMember]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cast = try container.decodeIfPresent([SeerrCastMember].self, forKey: .cast) ?? []
        crew = try container.decodeIfPresent([SeerrCrewMember].self, forKey: .crew) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case cast, crew
    }
}

nonisolated struct SeerrCastMember: Decodable, Hashable, Identifiable {
    /// Unique per role; the person id repeats when one actor plays two
    /// parts. Falls back to the person id rather than failing the page.
    let creditId: String
    let id: Int
    let name: String?
    let character: String?
    let profilePath: String?
    let order: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        creditId = try container.decodeIfPresent(String.self, forKey: .creditId) ?? "person-\(id)"
        name = try container.decodeIfPresent(String.self, forKey: .name)
        character = try container.decodeIfPresent(String.self, forKey: .character)
        profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
        order = try container.decodeIfPresent(Int.self, forKey: .order)
    }

    private enum CodingKeys: String, CodingKey {
        case creditId, id, name, character, profilePath, order
    }
}

nonisolated struct SeerrCrewMember: Decodable, Hashable, Identifiable {
    let creditId: String
    let id: Int
    let name: String?
    let job: String?
    let department: String?
    let profilePath: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        creditId = try container.decodeIfPresent(String.self, forKey: .creditId) ?? "crew-\(id)"
        name = try container.decodeIfPresent(String.self, forKey: .name)
        job = try container.decodeIfPresent(String.self, forKey: .job)
        department = try container.decodeIfPresent(String.self, forKey: .department)
        profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
    }

    private enum CodingKeys: String, CodingKey {
        case creditId, id, name, job, department, profilePath
    }
}

/// TMDB's `release_dates` block. Its keys are snake_case, unlike the rest of
/// Seerr, so these types carry their own keys.
nonisolated struct SeerrReleases: Decodable, Hashable {
    let results: [SeerrCountryReleases]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([SeerrCountryReleases].self, forKey: .results) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case results
    }
}

nonisolated struct SeerrCountryReleases: Decodable, Hashable {
    let iso3166_1: String
    let releaseDates: [SeerrReleaseDate]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iso3166_1 = try container.decodeIfPresent(String.self, forKey: .iso3166_1) ?? ""
        releaseDates = try container.decodeIfPresent([SeerrReleaseDate].self, forKey: .releaseDates) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case iso3166_1 = "iso_3166_1"
        case releaseDates = "release_dates"
    }
}

nonisolated struct SeerrReleaseDate: Decodable, Hashable {
    let certification: String?
}

nonisolated struct SeerrContentRatings: Decodable, Hashable {
    let results: [SeerrContentRating]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        results = try container.decodeIfPresent([SeerrContentRating].self, forKey: .results) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case results
    }
}

nonisolated struct SeerrContentRating: Decodable, Hashable {
    let iso3166_1: String
    let rating: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iso3166_1 = try container.decodeIfPresent(String.self, forKey: .iso3166_1) ?? ""
        rating = try container.decodeIfPresent(String.self, forKey: .rating) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case iso3166_1 = "iso_3166_1"
        case rating
    }
}

nonisolated struct SeerrGenre: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    /// TMDB backdrop paths; only `discover/genreslider/*` sends them, so
    /// elsewhere this is empty.
    let backdrops: [String]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        backdrops = try container.decodeIfPresent([String].self, forKey: .backdrops) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, backdrops
    }
}

nonisolated struct SeerrSeason: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String?
    let seasonNumber: Int
    let episodeCount: Int?
    let airDate: String?
    let posterPath: String?

    var displayName: String { name ?? "Season \(seasonNumber)" }
}

nonisolated struct SeerrMediaInfo: Decodable, Hashable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    let mediaType: SeerrMediaType?
    let status: Int?
    let status4k: Int?
    let externalServiceId: Int?
    let externalServiceId4k: Int?
    let jellyfinMediaId: String?
    let jellyfinMediaId4k: String?
    let requests: [SeerrRequestReference]?
    let seasons: [SeerrMediaSeasonStatus]?
    let downloadStatus: [SeerrDownloadItem]?
    let downloadStatus4k: [SeerrDownloadItem]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId)
        tvdbId = try container.decodeIfPresent(Int.self, forKey: .tvdbId)
        mediaType = try? container.decodeIfPresent(SeerrMediaType.self, forKey: .mediaType)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        status4k = try container.decodeIfPresent(Int.self, forKey: .status4k)
        externalServiceId = try container.decodeIfPresent(Int.self, forKey: .externalServiceId)
        externalServiceId4k = try container.decodeIfPresent(Int.self, forKey: .externalServiceId4k)
        jellyfinMediaId = try container.decodeIfPresent(String.self, forKey: .jellyfinMediaId)
        jellyfinMediaId4k = try container.decodeIfPresent(String.self, forKey: .jellyfinMediaId4k)
        requests = try container.decodeIfPresent([SeerrRequestReference].self, forKey: .requests)
        seasons = try container.decodeIfPresent([SeerrMediaSeasonStatus].self, forKey: .seasons)
        downloadStatus = try container.decodeIfPresent([SeerrDownloadItem].self, forKey: .downloadStatus)
        downloadStatus4k = try container.decodeIfPresent([SeerrDownloadItem].self, forKey: .downloadStatus4k)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tmdbId, tvdbId, mediaType, status, status4k
        case externalServiceId, externalServiceId4k, jellyfinMediaId, jellyfinMediaId4k
        case requests, seasons, downloadStatus, downloadStatus4k
    }

    var availability: SeerrAvailabilityStatus { .init(apiValue: status) }

    func downloadProgress(is4k: Bool = false) -> SeerrDownloadProgress? {
        SeerrDownloadProgress(items: (is4k ? downloadStatus4k : downloadStatus) ?? [])
    }
}

nonisolated struct SeerrMediaSeasonStatus: Decodable, Hashable, Identifiable {
    let id: Int
    let seasonNumber: Int
    let status: Int?
    let status4k: Int?

    var availability: SeerrAvailabilityStatus { .init(apiValue: status) }
}

nonisolated struct SeerrRequestReference: Decodable, Hashable, Identifiable {
    let id: Int
    let status: Int
    let is4k: Bool?
    let requestedBy: SeerrUser?
    let seasons: [SeerrRequestedSeason]?

    var requestStatus: SeerrRequestStatus { .init(apiValue: status) }
}

nonisolated struct SeerrRequestedSeason: Decodable, Hashable, Identifiable {
    let id: Int
    let seasonNumber: Int
    let status: Int?
}

nonisolated struct SeerrPageInfo: Decodable, Equatable {
    let page: Int
    let pages: Int
    let pageSize: Int?
    let results: Int
}

nonisolated struct SeerrRequestsPage: Decodable, Equatable {
    let pageInfo: SeerrPageInfo
    let results: [SeerrMediaRequest]
}

nonisolated struct SeerrMediaRequest: Decodable, Hashable, Identifiable {
    let id: Int
    let status: Int
    let type: SeerrMediaType?
    let media: SeerrRequestMedia?
    let requestedBy: SeerrUser?
    let createdAt: String?
    let updatedAt: String?
    let is4k: Bool?
    let seasons: [SeerrRequestedSeason]?
    /// The Radarr/Sonarr quality profile and server. Ids only; the names
    /// live on the service.
    let profileId: Int?
    let serverId: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        status = try container.decode(Int.self, forKey: .status)
        type = try? container.decodeIfPresent(SeerrMediaType.self, forKey: .type)
        media = try container.decodeIfPresent(SeerrRequestMedia.self, forKey: .media)
        requestedBy = try container.decodeIfPresent(SeerrUser.self, forKey: .requestedBy)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        is4k = try container.decodeIfPresent(Bool.self, forKey: .is4k)
        seasons = try container.decodeIfPresent([SeerrRequestedSeason].self, forKey: .seasons)
        profileId = try container.decodeIfPresent(Int.self, forKey: .profileId)
        serverId = try container.decodeIfPresent(Int.self, forKey: .serverId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, status, type, media, requestedBy, createdAt, updatedAt
        case is4k, seasons, profileId, serverId
    }

    var requestStatus: SeerrRequestStatus { .init(apiValue: status) }

    var progress: SeerrRequestProgress {
        .resolve(
            request: requestStatus,
            availability: media?.availability(is4k: is4k == true) ?? .unknown
        )
    }

    /// Only meaningful while `progress` is `.processing`.
    var downloadProgress: SeerrDownloadProgress? {
        media?.downloadProgress(is4k: is4k == true)
    }

    var resolvedMediaType: SeerrMediaType {
        type ?? media?.mediaType ?? (media?.tvdbId == nil ? .movie : .tv)
    }
    var tmdbID: Int? { media?.tmdbId }
}

nonisolated struct SeerrRequestMedia: Decodable, Hashable {
    let id: Int?
    let tmdbId: Int?
    let tvdbId: Int?
    let mediaType: SeerrMediaType?
    let status: Int?
    let status4k: Int?
    let externalServiceId: Int?
    let downloadStatus: [SeerrDownloadItem]?
    let downloadStatus4k: [SeerrDownloadItem]?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        tmdbId = try container.decodeIfPresent(Int.self, forKey: .tmdbId)
        tvdbId = try container.decodeIfPresent(Int.self, forKey: .tvdbId)
        mediaType = try? container.decodeIfPresent(SeerrMediaType.self, forKey: .mediaType)
        status = try container.decodeIfPresent(Int.self, forKey: .status)
        status4k = try container.decodeIfPresent(Int.self, forKey: .status4k)
        externalServiceId = try container.decodeIfPresent(Int.self, forKey: .externalServiceId)
        downloadStatus = try container.decodeIfPresent([SeerrDownloadItem].self, forKey: .downloadStatus)
        downloadStatus4k = try container.decodeIfPresent([SeerrDownloadItem].self, forKey: .downloadStatus4k)
    }

    private enum CodingKeys: String, CodingKey {
        case id, tmdbId, tvdbId, mediaType, status, status4k
        case externalServiceId, downloadStatus, downloadStatus4k
    }

    var availability: SeerrAvailabilityStatus { .init(apiValue: status) }

    /// A 4K request is satisfied only by the 4K copy.
    func availability(is4k: Bool) -> SeerrAvailabilityStatus {
        .init(apiValue: is4k ? status4k : status)
    }

    func downloadProgress(is4k: Bool) -> SeerrDownloadProgress? {
        SeerrDownloadProgress(items: (is4k ? downloadStatus4k : downloadStatus) ?? [])
    }
}

nonisolated struct SeerrQuickConnect: Decodable, Equatable {
    let code: String
    let secret: String
}

nonisolated struct SeerrQuickConnectState: Decodable, Equatable {
    let authenticated: Bool
}

/// A configured Radarr/Sonarr server as `service/{radarr,sonarr}` lists them.
nonisolated struct SeerrService: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    let is4k: Bool
    let isDefault: Bool
    /// Applied when a request names no profile, as Lagoon's never do.
    let activeProfileId: Int?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        is4k = try container.decodeIfPresent(Bool.self, forKey: .is4k) ?? false
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
        activeProfileId = try container.decodeIfPresent(Int.self, forKey: .activeProfileId)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, is4k, isDefault, activeProfileId
    }
}

nonisolated struct SeerrQualityProfile: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
    }
}

nonisolated struct SeerrServiceDetails: Decodable, Hashable {
    let profiles: [SeerrQualityProfile]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([SeerrQualityProfile].self, forKey: .profiles) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case profiles
    }
}

nonisolated struct SeerrCreateRequest: Encodable, Equatable {
    let mediaType: SeerrMediaType
    let mediaId: Int
    let seasons: [Int]?
    let is4k: Bool?
}

nonisolated enum SeerrRequestFilter: String, CaseIterable, Identifiable {
    case all
    case pending
    case approved
    case processing
    case available
    case failed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

// MARK: - Discover layout

/// Jellyseerr's Discover slider types. `settings/discover` sends bare numbers
/// with `title: null` for built-ins, so the meaning and wording live here, as
/// in Jellyseerr's web client.
nonisolated enum SeerrDiscoverSliderType: Int, Decodable, Hashable {
    case recentlyAdded = 1
    case recentRequests
    case watchlist
    case trending
    case popularMovies
    case movieGenres
    case upcomingMovies
    case studios
    case popularTV
    case tvGenres
    case upcomingTV
    case networks
    case tmdbMovieKeyword
    case tmdbMovieGenre
    case tmdbTVKeyword
    case tmdbTVGenre
    case tmdbSearch
    case tmdbStudio
    case tmdbNetwork
    case tmdbMovieStreamingServices
    case tmdbTVStreamingServices
}

nonisolated struct SeerrDiscoverSlider: Decodable, Hashable, Identifiable {
    let id: Int
    /// Nil for a type this build does not know; skip it rather than fail the
    /// layout.
    let type: SeerrDiscoverSliderType?
    let order: Int
    let enabled: Bool
    let title: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id) ?? 0
        type = try? container.decodeIfPresent(SeerrDiscoverSliderType.self, forKey: .type)
        order = try container.decodeIfPresent(Int.self, forKey: .order) ?? 0
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        title = try container.decodeIfPresent(String.self, forKey: .title)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, order, enabled, title
    }
}

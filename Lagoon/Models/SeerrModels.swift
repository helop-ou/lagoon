import Foundation

// Seerr/Jellyseerr deliberately has its own model layer. Its numeric ids are
// TMDB ids, not Jellyfin item ids, and conflating the two makes navigation and
// availability state subtly unsafe.

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
    /// Lifting a block is an administrator's job; `hasPermission` already
    /// treats the admin flag as an override (HEL-115).
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

/// Values are the public bit flags from Seerr's permissions contract. Admin
/// is handled as an override by `SeerrUser.hasPermission`, matching Seerr.
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
/// spelled out rather than left to `case` order — 6 was previously read as
/// "deleted" when it is *blocklisted*, which offered a Request button for a
/// title the server would refuse, and pushed the real deleted value (7) into
/// the unknown fallback (HEL-115).
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
        // The media record is gone, so as far as a viewer is concerned the
        // title is simply not in the library and can be asked for again.
        case .deleted: "Not Requested"
        }
    }

    /// Deleted media can be requested afresh; blocklisted media cannot, and
    /// offering the button anyway only earns a rejection from the server.
    var allowsRequesting: Bool {
        self == .unknown || self == .deleted
    }

    /// Whether the title is in the library to any degree.
    var isPlayable: Bool {
        self == .available || self == .partiallyAvailable
    }
}

/// Jellyseerr's `MediaRequestStatus`. Lagoon knew only 1-3 and read anything
/// else as `.pending`, so a **completed** request — what an approved request
/// becomes once the title lands in the library — reported "Pending Approval"
/// forever, and a failed one did too (HEL-115).
///
/// An unrecognised value is now its own case rather than a fourth way to say
/// pending: claiming a state we do not understand is what caused that bug.
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

    /// Approved and completed both mean "the server said yes"; only the
    /// library tells you whether it has arrived yet.
    var isGranted: Bool {
        self == .approved || self == .completed
    }
}

/// What a viewer actually wants to know about a request: not where it sits in
/// Jellyseerr's approval bookkeeping, but whether they can watch it yet.
///
/// The request's own status answers that only until it is approved; after
/// that the media's availability does. Keeping both in one value is what
/// stops an approved-and-available title reading as "Approved" while it is
/// sitting in the library ready to play (HEL-115).
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
            // Exhaustive on purpose. A `default:` here is what produced the
            // original bug in the first place: it quietly reported a specific,
            // reassuring state for one nobody had thought about. Adding a case
            // to `SeerrAvailabilityStatus` should fail this switch and make
            // someone decide (HEL-115).
            switch availability {
            case .available: .available
            case .partiallyAvailable: .partiallyAvailable
            // Jellyseerr models this as its own filter — a completed request
            // whose media has since been removed. It is finished, not still
            // arriving.
            case .deleted: .removed
            case .blocklisted: .blocked
            // Granted, not in the library yet.
            case .unknown, .pending, .processing: .processing
            }
        }
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

    var displayTitle: String { title ?? name ?? originalTitle ?? originalName ?? "Untitled" }
    var date: String? { releaseDate ?? firstAirDate }
    var year: String? { date.map { String($0.prefix(4)) }.flatMap { $0.isEmpty ? nil : $0 } }
}

nonisolated struct SeerrGenre: Decodable, Hashable, Identifiable {
    let id: Int
    let name: String
    /// Only `discover/genreslider/*` sends these — a handful of TMDB backdrop
    /// paths to draw the genre with. A detail page's genres carry none, so
    /// this is empty there rather than absent (HEL-114).
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

    var availability: SeerrAvailabilityStatus { .init(apiValue: status) }
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

    var requestStatus: SeerrRequestStatus { .init(apiValue: status) }

    /// What to show for this request: its approval state until it is granted,
    /// and the library's answer after that (HEL-115).
    var progress: SeerrRequestProgress {
        .resolve(
            request: requestStatus,
            availability: media?.availability(is4k: is4k == true) ?? .unknown
        )
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

    var availability: SeerrAvailabilityStatus { .init(apiValue: status) }

    /// A 4K request is satisfied by the 4K copy, not by the 1080p one that
    /// may already be sitting in the library.
    func availability(is4k: Bool) -> SeerrAvailabilityStatus {
        .init(apiValue: is4k ? status4k : status)
    }
}

nonisolated struct SeerrQuickConnect: Decodable, Equatable {
    let code: String
    let secret: String
}

nonisolated struct SeerrQuickConnectState: Decodable, Equatable {
    let authenticated: Bool
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

/// The slider types Jellyseerr's own Discover page is built from. The server
/// sends `settings/discover` as bare type numbers with `title: null` for
/// built-ins, so the meaning of each number lives here and the wording is
/// ours — the same arrangement Jellyseerr's web client uses.
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
    /// Unknown to this build when nil: a newer Jellyseerr can add slider
    /// types, and one Lagoon has never heard of must be skipped rather than
    /// fail the whole layout.
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

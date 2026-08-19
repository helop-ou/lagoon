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

nonisolated enum SeerrAvailabilityStatus: Int, Hashable {
    case unknown = 1
    case pending = 2
    case processing = 3
    case partiallyAvailable = 4
    case available = 5
    case deleted = 6

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
        case .deleted: "Unavailable"
        }
    }
}

nonisolated enum SeerrRequestStatus: Int, Hashable {
    case pending = 1
    case approved = 2
    case declined = 3

    init(apiValue: Int) {
        self = Self(rawValue: apiValue) ?? .pending
    }

    var title: String {
        switch self {
        case .pending: "Pending Approval"
        case .approved: "Approved"
        case .declined: "Declined"
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

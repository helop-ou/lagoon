import Foundation

// Jellyfin JSON uses PascalCase keys; the client's de/encoders convert to and
// from camelCase globally, so these types need no per-field CodingKeys.

// MARK: - Server & auth

nonisolated struct PublicSystemInfo: Decodable {
    let serverName: String?
    let version: String?
    let id: String?
}

nonisolated struct UserDto: Codable, Identifiable {
    let id: String
    let name: String?
    let serverId: String?
    let primaryImageTag: String?
}

nonisolated struct AuthenticationResult: Decodable {
    let user: UserDto
    let accessToken: String
    let serverId: String?
}

nonisolated struct QuickConnectResult: Decodable {
    let authenticated: Bool
    let secret: String
    let code: String
}

// MARK: - Items

nonisolated enum MediaItemType: String, Decodable {
    case movie = "Movie"
    case series = "Series"
    case season = "Season"
    case episode = "Episode"
    case boxSet = "BoxSet"
    case collectionFolder = "CollectionFolder"
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MediaItemType(rawValue: raw) ?? .other
    }
}

nonisolated struct UserItemData: Decodable {
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?
    let unplayedItemCount: Int?
    let isFavorite: Bool?
}

nonisolated struct MediaItem: Decodable, Identifiable {
    let id: String
    let name: String?
    let type: MediaItemType
    let collectionType: String?
    let overview: String?
    let taglines: [String]?
    let genres: [String]?
    let productionYear: Int?
    let communityRating: Double?
    let officialRating: String?
    let runTimeTicks: Int64?
    let status: String?
    let childCount: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let seasonName: String?
    let userData: UserItemData?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let seriesPrimaryImageTag: String?
    let mediaSources: [MediaSource]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try c.decode(String.self, forKey: "id")
        name = try c.decodeIfPresent(String.self, forKey: "name")
        type = (try? c.decode(MediaItemType.self, forKey: "type")) ?? .other
        collectionType = try c.decodeIfPresent(String.self, forKey: "collectionType")
        overview = try c.decodeIfPresent(String.self, forKey: "overview")
        taglines = try c.decodeIfPresent([String].self, forKey: "taglines")
        genres = try c.decodeIfPresent([String].self, forKey: "genres")
        productionYear = try c.decodeIfPresent(Int.self, forKey: "productionYear")
        communityRating = try c.decodeIfPresent(Double.self, forKey: "communityRating")
        officialRating = try c.decodeIfPresent(String.self, forKey: "officialRating")
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: "runTimeTicks")
        status = try c.decodeIfPresent(String.self, forKey: "status")
        childCount = try c.decodeIfPresent(Int.self, forKey: "childCount")
        indexNumber = try c.decodeIfPresent(Int.self, forKey: "indexNumber")
        parentIndexNumber = try c.decodeIfPresent(Int.self, forKey: "parentIndexNumber")
        seriesId = try c.decodeIfPresent(String.self, forKey: "seriesId")
        seriesName = try c.decodeIfPresent(String.self, forKey: "seriesName")
        seasonId = try c.decodeIfPresent(String.self, forKey: "seasonId")
        seasonName = try c.decodeIfPresent(String.self, forKey: "seasonName")
        userData = try? c.decodeIfPresent(UserItemData.self, forKey: "userData")
        imageTags = try c.decodeIfPresent([String: String].self, forKey: "imageTags")
        backdropImageTags = try c.decodeIfPresent([String].self, forKey: "backdropImageTags")
        parentBackdropItemId = try c.decodeIfPresent(String.self, forKey: "parentBackdropItemId")
        parentBackdropImageTags = try c.decodeIfPresent([String].self, forKey: "parentBackdropImageTags")
        seriesPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: "seriesPrimaryImageTag")
        mediaSources = try? c.decodeIfPresent([MediaSource].self, forKey: "mediaSources")
    }
}

// Identity-based Hashable so items can be NavigationStack destinations.
nonisolated extension MediaItem: Hashable {
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

nonisolated struct ItemsPage: Decodable {
    let items: [MediaItem]
    let totalRecordCount: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        items = try c.decodeIfPresent([MediaItem].self, forKey: "items") ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: "totalRecordCount")
    }
}

// MARK: - Playback

nonisolated struct PlaybackInfoResponse: Decodable {
    let mediaSources: [MediaSource]
    let playSessionId: String?
    let errorCode: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        mediaSources = try c.decodeIfPresent([MediaSource].self, forKey: "mediaSources") ?? []
        playSessionId = try c.decodeIfPresent(String.self, forKey: "playSessionId")
        errorCode = try c.decodeIfPresent(String.self, forKey: "errorCode")
    }
}

nonisolated struct MediaSource: Decodable, Identifiable {
    let id: String
    let name: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    let transcodingUrl: String?
    let transcodingSubProtocol: String?
    let runTimeTicks: Int64?
    let bitrate: Int?
    let size: Int64?
    let eTag: String?
    // The server resolves the user's language preferences into these
    // default stream choices — no client-side preference logic needed.
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let mediaStreams: [MediaStream]?
}

nonisolated struct MediaStream: Decodable {
    let type: String?
    let codec: String?
    let displayTitle: String?
    let language: String?
    let index: Int?
    let isDefault: Bool?
    let isExternal: Bool?
    let deliveryUrl: String?
    let profile: String?
    let videoRangeType: String?
    let channels: Int?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let realFrameRate: Double?
}

/// A chapter marker (HEL-39 slice 3). Both list and single-item responses
/// carry these; servers that never scanned chapters just send an empty list.
nonisolated struct ChapterInfo: Decodable {
    let startPositionTicks: Int64
    let name: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        startPositionTicks = try c.decodeIfPresent(Int64.self, forKey: "startPositionTicks") ?? 0
        name = try c.decodeIfPresent(String.self, forKey: "name")
    }
}

/// One trickplay resolution's tile-sheet geometry (Jellyfin 10.9+). Each
/// sheet is a `tileWidth × tileHeight` grid of `width × height` thumbnails,
/// `interval` **milliseconds** apart, served from
/// `Videos/{id}/Trickplay/{width}/{sheet}.jpg`.
nonisolated struct TrickplayTileInfo: Decodable {
    let width: Int
    let height: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailCount: Int
    let interval: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        width = try c.decodeIfPresent(Int.self, forKey: "width") ?? 0
        height = try c.decodeIfPresent(Int.self, forKey: "height") ?? 0
        tileWidth = try c.decodeIfPresent(Int.self, forKey: "tileWidth") ?? 0
        tileHeight = try c.decodeIfPresent(Int.self, forKey: "tileHeight") ?? 0
        thumbnailCount = try c.decodeIfPresent(Int.self, forKey: "thumbnailCount") ?? 0
        interval = try c.decodeIfPresent(Int.self, forKey: "interval") ?? 0
    }
}

nonisolated enum PlayMethod: String {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

// MARK: - Ticks

// Jellyfin measures positions and durations in .NET ticks: 100 ns units.
nonisolated enum Ticks {
    static let perSecond: Int64 = 10_000_000

    static func seconds(_ ticks: Int64) -> Double {
        Double(ticks) / Double(perSecond)
    }

    static func ticks(_ seconds: Double) -> Int64 {
        Int64(seconds * Double(perSecond))
    }
}

// MARK: - Decoding helpers

nonisolated struct AnyCodingKey: CodingKey, ExpressibleByStringLiteral {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(stringLiteral value: String) { stringValue = value }
}

import Foundation
import LagoonEngine

// Jellyfin JSON is PascalCase; the client's coders convert it globally, so
// never add CodingKeys for casing.

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
    let policy: UserPolicy?
}

/// Account permissions Lagoon acts on. Without subtitle management (off by
/// default for non-admins) Jellyfin answers 403 to remote subtitle calls.
nonisolated struct UserPolicy: Codable {
    let isAdministrator: Bool?
    let enableSubtitleManagement: Bool?
    /// "Allow media downloading": gates `Items/{id}/Download`.
    let enableContentDownloading: Bool?
    /// "Allow video remuxing/transcoding": without it download transcodes
    /// answer 403.
    let enableVideoPlaybackTranscoding: Bool?
    /// Create, join only, or neither. Absent on older servers, which reads
    /// as `unknown`, not a denial.
    let syncPlayAccess: SyncPlayAccess?

    /// Pre-flight check only; the server decides. Block only on a known
    /// denial and let anything ambiguous through.
    ///
    /// Admins always pass: the dashboard hides the flag for them, so it is
    /// often stored `false` and must not read as a denial.
    var allowsSubtitleManagement: Bool {
        if isAdministrator == true { return true }
        return enableSubtitleManagement ?? true
    }
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

nonisolated enum MediaItemType: String, Codable, Hashable {
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

nonisolated struct UserItemData: Decodable, Hashable {
    let playbackPositionTicks: Int64?
    let playedPercentage: Double?
    let played: Bool?
    let isFavorite: Bool?
}

nonisolated struct MediaItem: Decodable, Identifiable {
    let id: String
    let name: String?
    let type: MediaItemType
    let collectionType: String?
    let overview: String?
    let genres: [String]?
    let productionYear: Int?
    let communityRating: Double?
    let officialRating: String?
    let runTimeTicks: Int64?
    let status: String?
    let originalLanguage: String?
    let childCount: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let userData: UserItemData?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let seriesPrimaryImageTag: String?
    let providerIds: [String: String]?
    let mediaSources: [MediaSource]?
    /// Only the single-item endpoint returns these; rail items have none.
    let people: [Person]?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try c.decode(String.self, forKey: "id")
        name = try c.decodeIfPresent(String.self, forKey: "name")
        type = (try? c.decode(MediaItemType.self, forKey: "type")) ?? .other
        collectionType = try c.decodeIfPresent(String.self, forKey: "collectionType")
        overview = try c.decodeIfPresent(String.self, forKey: "overview")
        genres = try c.decodeIfPresent([String].self, forKey: "genres")
        productionYear = try c.decodeIfPresent(Int.self, forKey: "productionYear")
        communityRating = try c.decodeIfPresent(Double.self, forKey: "communityRating")
        officialRating = try c.decodeIfPresent(String.self, forKey: "officialRating")
        runTimeTicks = try c.decodeIfPresent(Int64.self, forKey: "runTimeTicks")
        status = try c.decodeIfPresent(String.self, forKey: "status")
        originalLanguage = try c.decodeIfPresent(String.self, forKey: "originalLanguage")
        childCount = try c.decodeIfPresent(Int.self, forKey: "childCount")
        indexNumber = try c.decodeIfPresent(Int.self, forKey: "indexNumber")
        parentIndexNumber = try c.decodeIfPresent(Int.self, forKey: "parentIndexNumber")
        seriesId = try c.decodeIfPresent(String.self, forKey: "seriesId")
        seriesName = try c.decodeIfPresent(String.self, forKey: "seriesName")
        seasonId = try c.decodeIfPresent(String.self, forKey: "seasonId")
        userData = try? c.decodeIfPresent(UserItemData.self, forKey: "userData")
        imageTags = try c.decodeIfPresent([String: String].self, forKey: "imageTags")
        backdropImageTags = try c.decodeIfPresent([String].self, forKey: "backdropImageTags")
        parentBackdropItemId = try c.decodeIfPresent(String.self, forKey: "parentBackdropItemId")
        parentBackdropImageTags = try c.decodeIfPresent([String].self, forKey: "parentBackdropImageTags")
        seriesPrimaryImageTag = try c.decodeIfPresent(String.self, forKey: "seriesPrimaryImageTag")
        providerIds = try c.decodeIfPresent([String: String].self, forKey: "providerIds")
        mediaSources = try? c.decodeIfPresent([MediaSource].self, forKey: "mediaSources")
        people = try? c.decodeIfPresent([Person].self, forKey: "people")
    }
}

// Synthesized value equality; never an id-only `==`. SwiftUI drops a state
// write whose new value compares equal, so an id-only `==` hides a refreshed
// resume point. Navigation identity lives on `ContentNavigationRoute`.
nonisolated extension MediaItem: Hashable {}

nonisolated struct ItemsPage: Decodable {
    let items: [MediaItem]
    let totalRecordCount: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        items = try c.decodeIfPresent([MediaItem].self, forKey: "items") ?? []
        totalRecordCount = try c.decodeIfPresent(Int.self, forKey: "totalRecordCount")
    }
}

/// Item queries filter by `name`, which older servers support too.
nonisolated struct MediaGenre: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

nonisolated struct GenresPage: Decodable {
    let items: [MediaGenre]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        items = try c.decodeIfPresent([MediaGenre].self, forKey: "items") ?? []
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

nonisolated struct MediaSource: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    let container: String?
    /// `VideoFile`, `Iso`, `BluRay` or `Dvd`. The only field that marks a
    /// disc image or folder: Jellyfin reports the inner container (`ts`) and
    /// still claims `SupportsDirectPlay`.
    let videoType: String?
    /// `BluRay` or `Dvd` when `videoType` is `Iso`; nil otherwise.
    let isoType: String?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let transcodingUrl: String?
    let transcodingSubProtocol: String?
    let runTimeTicks: Int64?
    let bitrate: Int?
    let size: Int64?
    let eTag: String?
    // The server's own language preference; Lagoon may override it.
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let mediaStreams: [MediaStream]?
}

/// Headshots live at `Items/{person.id}/Images/Primary`, gated on
/// `primaryImageTag`.
nonisolated struct Person: Decodable, Identifiable, Hashable {
    let id: String
    let name: String?
    /// The character for actors; nil for crew.
    let role: String?
    /// "Actor", "Director", "Writer", …
    let type: String?
    let primaryImageTag: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try c.decode(String.self, forKey: "id")
        name = try c.decodeIfPresent(String.self, forKey: "name")
        role = try c.decodeIfPresent(String.self, forKey: "role")
        type = try c.decodeIfPresent(String.self, forKey: "type")
        primaryImageTag = try c.decodeIfPresent(String.self, forKey: "primaryImageTag")
    }
}

nonisolated struct MediaStream: Decodable, Hashable {
    let type: String?
    let codec: String?
    let displayTitle: String?
    /// The title the file carries, nil when untagged. `displayTitle` is
    /// synthesized from codec and layout, so only this shows a track is
    /// anonymous.
    let title: String?
    let language: String?
    let index: Int?
    let isDefault: Bool?
    let isOriginal: Bool?
    let isExternal: Bool?
    let isForced: Bool?
    let isHearingImpaired: Bool?
    let deliveryUrl: String?
    let profile: String?
    let videoRangeType: String?
    let channels: Int?
    let width: Int?
    let height: Int?
    let bitDepth: Int?
    let bitRate: Int?
    let realFrameRate: Double?
}

/// A result from Jellyfin's subtitle providers.
nonisolated struct RemoteSubtitleInfo: Decodable, Identifiable, Equatable {
    let id: String
    let name: String?
    let threeLetterISOLanguageName: String?
    let providerName: String?
    let format: String?
    let comment: String?
    let communityRating: Double?
    let downloadCount: Int?
    let isHashMatch: Bool?
    let hearingImpaired: Bool?
    let isForced: Bool?
    let machineTranslated: Bool?
    let aiTranslated: Bool?
    let frameRate: Double?
}

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

/// Shared so the player's Info facts and the detail badges agree on what
/// counts as 4K or Dolby Vision.
nonisolated enum MediaQuality {
    static func resolutionClass(width: Int) -> String {
        switch width {
        case 3200...: "4K"
        case 1800..<3200: "1080p"
        case 1200..<1800: "720p"
        default: "SD"
        }
    }

    /// Compact form for the player's facts line ("HEVC (4K DV)").
    static func rangeLabel(_ range: String) -> String {
        if range.hasPrefix("DOVI") { return "DV" }
        if range == "HDR10Plus" { return "HDR10+" }
        return range
    }

    static func audioName(_ codec: String) -> String {
        switch codec.lowercased() {
        case "truehd": "TrueHD"
        case "eac3": "Dolby Digital+"
        case "ac3": "Dolby Digital"
        case "dts": "DTS"
        case "aac": "AAC"
        case "flac": "FLAC"
        default: codec.uppercased()
        }
    }

    static func channelLayout(_ channels: Int) -> String? {
        switch channels {
        case 8: "7.1"
        case 6: "5.1"
        case 2: "2.0"
        case 1: "1.0"
        default: nil
        }
    }
}

extension MediaSource {
    /// "4K DV TrueHD 7.1 Atmos": the best the file can do, not the selected
    /// track.
    var qualityTokens: [String] {
        let streams = mediaStreams ?? []
        var tokens: [String] = []

        if let video = streams.first(where: { $0.type == "Video" }) {
            if let width = video.width {
                tokens.append(MediaQuality.resolutionClass(width: width))
            }
            if let range = video.videoRangeType, range != "SDR" {
                tokens.append(MediaQuality.rangeLabel(range))
            }
        }

        let audio = streams.filter { $0.type == "Audio" }
        // Rank by what a viewer would call "best": lossless over lossy, more
        // channels over fewer.
        let best = audio.max { lhs, rhs in
            (Self.audioRank(lhs), lhs.channels ?? 0) < (Self.audioRank(rhs), rhs.channels ?? 0)
        }
        if let best, let codec = best.codec {
            var name = MediaQuality.audioName(codec)
            if let channels = best.channels, let layout = MediaQuality.channelLayout(channels) {
                name += " \(layout)"
            }
            tokens.append(name)
        }
        if audio.contains(where: { $0.profile?.localizedCaseInsensitiveContains("atmos") == true }) {
            tokens.append("Atmos")
        }

        return tokens
    }

    private static func audioRank(_ stream: MediaStream) -> Int {
        switch stream.codec?.lowercased() {
        case "truehd": 4
        case "dts": 3
        case "eac3": 2
        case "ac3": 1
        default: 0
        }
    }
}

nonisolated enum PlayMethod: String {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"

    /// Direct play and direct stream are one stable file; a transcode is a
    /// manifest the server writes as playback advances.
    var delivery: MediaDelivery {
        switch self {
        case .directPlay, .directStream: .stableFile
        case .transcode: .segmentedManifest
        }
    }
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

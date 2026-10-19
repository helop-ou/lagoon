import Foundation

// Home Screen Sections plugin. Optional: without it, or on any error, Home
// uses its own rails.
extension JellyfinClient {
    /// One row the plugin offers, as `HomeScreen/Sections` describes it.
    nonisolated struct HomeSection: Decodable, Identifiable, Sendable {
        /// The section key (`ContinueWatching`, `MyList`), also its fetch path.
        let section: String
        let displayText: String?
        /// `Landscape`, `Portrait` or `Square` (drawn as a poster rail).
        let viewMode: String?
        let orderIndex: Int?
        /// Which person, genre or library; the section fetches empty without it.
        let additionalData: String?

        var id: String {
            additionalData.map { "\(section)|\($0)" } ?? section
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            section = try c.decode(String.self, forKey: "section")
            displayText = try c.decodeIfPresent(String.self, forKey: "displayText")
            viewMode = try c.decodeIfPresent(String.self, forKey: "viewMode")
            orderIndex = try c.decodeIfPresent(Int.self, forKey: "orderIndex")
            additionalData = (try? c.decodeIfPresent(String.self, forKey: "additionalData"))
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private nonisolated struct HomeSectionsPage: Decodable {
        let items: [HomeSection]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            items = try c.decodeIfPresent([HomeSection].self, forKey: "items") ?? []
        }
    }

    /// Section types the plugin offers, empty when it isn't installed.
    ///
    /// A catalogue, not a layout: every type the plugin knows, whatever the
    /// admin enabled, and nothing exposes the enabled set. So `HomeViewModel`
    /// adds these as extra rows rather than letting them define Home.
    func homeSections() async -> [HomeSection] {
        guard let userId else { return [] }
        let page: HomeSectionsPage? = try? await get("HomeScreen/Sections", query: [
            URLQueryItem(name: "userId", value: userId),
        ], probe: true)
        let legacy = page?.items ?? []
        var seen = Set<String>()
        return legacy.filter { seen.insert($0.id).inserted }
    }

    /// Not in the library: the plugin gives it a random or all-zero `Id`, so
    /// Jellyfin artwork and item pages for it 404.
    nonisolated struct ExternalSectionItem: Decodable, Identifiable, Hashable, Sendable {
        /// Stable across requests, unlike the plugin's `Id`.
        let id: String
        let title: String
        let subtitle: String?
        let posterPath: String?
        let seerrID: Int?
        let seerrType: SeerrMediaType?
        let year: Int?
        let seerrAddress: String?

        private static let sources = [
            (name: "Sonarr", idKey: "SonarrEpisodeId"),
            (name: "Radarr", idKey: "RadarrMovieId"),
            (name: "Lidarr", idKey: "LidarrAlbumId"),
            (name: "Readarr", idKey: "ReadarrBookId"),
            (name: "Jellyseerr", idKey: "Jellyseerr"),
        ]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            let providerIds = (try? c.decodeIfPresent([String: String].self, forKey: "providerIds")) ?? [:]
            // The key strategy lowercases the first letter of these keys too.
            func value(_ key: String) -> String? {
                providerIds.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                    .map(\.value).flatMap { $0.isEmpty ? nil : $0 }
            }
            guard let (source, sourceID) = Self.sources.lazy
                .compactMap({ source in value(source.idKey).map { (source.name, $0) } })
                .first
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: "providerIds", in: c, debugDescription: "A library item"
                )
            }
            let name = try? c.decodeIfPresent(String.self, forKey: "name")
            title = name ?? ""
            year = try? c.decodeIfPresent(Int.self, forKey: "productionYear")
            posterPath = value("\(source)Poster")
            seerrAddress = value("JellyseerrRoot")

            let formattedDate = value("FormattedDate")
            switch source {
            case "Sonarr":
                let episode = EpisodeLabel.text(
                    season: try? c.decodeIfPresent(Int.self, forKey: "parentIndexNumber"),
                    episode: try? c.decodeIfPresent(Int.self, forKey: "indexNumber"),
                    episodeEnd: nil
                )
                subtitle = [episode, formattedDate].compactMap { $0 }.joined(separator: " · ")
            case "Jellyseerr":
                // The plugin writes 1970-01-01 when Seerr has no date.
                let premiere = (try? c.decodeIfPresent(String.self, forKey: "premiereDate")) ?? ""
                let year = String(premiere.prefix(4))
                subtitle = year.count == 4 && year != "1970" ? year : nil
            default:
                subtitle = formattedDate
            }

            let mediaType = (try? c.decodeIfPresent(String.self, forKey: "sourceType"))
                .flatMap(SeerrMediaType.init(rawValue:))
            if source == "Jellyseerr", let mediaType, mediaType != .person {
                seerrID = Int(sourceID)
                seerrType = mediaType
                // A movie and a show can share a TMDB id.
                id = "\(source):\(mediaType.rawValue):\(sourceID)"
            } else {
                seerrID = nil
                seerrType = switch source {
                case "Sonarr": .tv
                case "Radarr": .movie
                default: nil
                }
                id = "\(source):\(sourceID)"
            }
        }
    }

    nonisolated struct HomeSectionContents: Sendable {
        var items: [MediaItem] = []
        var externalItems: [ExternalSectionItem] = []

        var isEmpty: Bool { items.isEmpty && externalItems.isEmpty }
    }

    private nonisolated enum HomeSectionEntry: Decodable {
        case library(MediaItem)
        case external(ExternalSectionItem)

        init(from decoder: Decoder) throws {
            if let external = try? ExternalSectionItem(from: decoder) {
                self = .external(external)
            } else {
                self = .library(try MediaItem(from: decoder))
            }
        }
    }

    private nonisolated struct HomeSectionEntriesPage: Decodable {
        let items: [HomeSectionEntry]
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            items = try c.decodeIfPresent([HomeSectionEntry].self, forKey: "items") ?? []
        }
    }

    /// A section's contents. Empty on failure, so one bad section costs
    /// nothing else.
    func homeSectionContents(_ section: HomeSection) async -> HomeSectionContents {
        guard let userId else { return HomeSectionContents() }
        var query = [URLQueryItem(name: "userId", value: userId)]
        if let additionalData = section.additionalData {
            query.append(URLQueryItem(name: "additionalData", value: additionalData))
        }
        let page: HomeSectionEntriesPage? = try? await get(
            "HomeScreen/Section/\(section.section)", query: query, probe: true
        )
        var contents = HomeSectionContents()
        var seen = Set<String>()
        for entry in page?.items ?? [] {
            switch entry {
            case .library(let item):
                contents.items.append(item)
            case .external(let item):
                // Seerr's pages can repeat a title.
                if seen.insert(item.id).inserted { contents.externalItems.append(item) }
            }
        }
        return contents
    }
}

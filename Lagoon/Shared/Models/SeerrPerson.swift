import Foundation

/// A TMDB person as Seerr lists them, with what their page needs before it
/// loads. Seerr's cast, crew and search results all carry it.
nonisolated struct SeerrPerson: Hashable, Identifiable {
    /// The TMDB person id.
    let id: Int
    let name: String
    let profilePath: String?
}

/// `person/{id}`: TMDB's biography. The dates are plain `yyyy-MM-dd` and stay
/// strings, like Jellyfin's.
nonisolated struct SeerrPersonDetails: Decodable, Hashable {
    let id: Int
    let name: String?
    let biography: String?
    let birthday: String?
    let deathday: String?
    let placeOfBirth: String?
    let profilePath: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        biography = try? container.decodeIfPresent(String.self, forKey: .biography)
        birthday = try? container.decodeIfPresent(String.self, forKey: .birthday)
        deathday = try? container.decodeIfPresent(String.self, forKey: .deathday)
        placeOfBirth = try? container.decodeIfPresent(String.self, forKey: .placeOfBirth)
        profilePath = try? container.decodeIfPresent(String.self, forKey: .profilePath)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, biography, birthday, deathday, placeOfBirth, profilePath
    }
}

/// `person/{id}/combined_credits`: every movie and show TMDB credits them
/// with, one entry per role.
nonisolated struct SeerrPersonCredits: Decodable, Hashable {
    let cast: [SeerrPersonCredit]
    let crew: [SeerrPersonCredit]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cast = (try? container.decodeIfPresent([LossyCredit].self, forKey: .cast))?.compactMap(\.credit) ?? []
        crew = (try? container.decodeIfPresent([LossyCredit].self, forKey: .crew))?.compactMap(\.credit) ?? []
    }

    init(cast: [SeerrPersonCredit], crew: [SeerrPersonCredit]) {
        self.cast = cast
        self.crew = crew
    }

    private enum CodingKeys: String, CodingKey {
        case cast, crew
    }

    /// A career runs to hundreds of credits. One without an id costs that
    /// credit, not the rail.
    private struct LossyCredit: Decodable {
        let credit: SeerrPersonCredit?

        init(from decoder: Decoder) throws {
            credit = try? SeerrPersonCredit(from: decoder)
        }
    }

    /// TMDB's News, Reality and Talk genres: appearances as themselves.
    static let selfAppearanceGenres: Set<Int> = [10763, 10764, 10767]

    /// The person page's TMDB rail: movies and shows with a poster, one card
    /// per title however many roles, best known first. Leaves out
    /// self-appearances and anything the library already has, by Seerr's
    /// availability or by the library's own TMDB ids (`"movie:13"`), so no
    /// title sits in both rails.
    func filmography(excluding libraryKeys: Set<String> = []) -> [SeerrDiscoverResult] {
        let candidates = (cast + crew).filter { credit in
            Self.belongsInRail(credit) && !libraryKeys.contains(Self.key(credit.media))
        }
        let ranked = candidates.sorted { lhs, rhs in
            if lhs.voteCount != rhs.voteCount { return lhs.voteCount > rhs.voteCount }
            return lhs.media.id < rhs.media.id
        }
        var seen = Set<String>()
        return ranked.filter { seen.insert(Self.key($0.media)).inserted }.map(\.media)
    }

    private static func belongsInRail(_ credit: SeerrPersonCredit) -> Bool {
        let media = credit.media
        guard media.mediaType == .movie || media.mediaType == .tv,
              let poster = media.posterPath, !poster.isEmpty,
              !credit.isSelfAppearance else { return false }
        let availability = media.mediaInfo?.availability ?? .unknown
        return availability != .available && availability != .partiallyAvailable
    }

    /// One title's identity across both rails: TMDB ids repeat between
    /// movies and shows.
    static func key(_ media: SeerrDiscoverResult) -> String {
        "\(media.mediaType?.rawValue ?? "unknown"):\(media.id)"
    }

    /// The same identity for a library title, from its TMDB provider id.
    static func key(_ item: MediaItem) -> String? {
        guard let tmdbID = item.providerIds?.first(where: { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame })?.value,
              !tmdbID.isEmpty else { return nil }
        switch item.type {
        case .movie: return "movie:\(tmdbID)"
        case .series: return "tv:\(tmdbID)"
        default: return nil
        }
    }
}

/// One credit: the title as a discover result, so the rail reuses Seerr's
/// cards, and the role.
nonisolated struct SeerrPersonCredit: Decodable, Hashable {
    let media: SeerrDiscoverResult
    /// The character for cast. Crew has a job instead.
    let character: String?
    let genreIDs: [Int]
    let voteCount: Int

    init(from decoder: Decoder) throws {
        media = try SeerrDiscoverResult(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        character = try? container.decodeIfPresent(String.self, forKey: .character)
        genreIDs = (try? container.decodeIfPresent([Int].self, forKey: .genreIds)) ?? []
        voteCount = (try? container.decodeIfPresent(Int.self, forKey: .voteCount)) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case character, genreIds, voteCount
    }

    /// A talk show, the news, reality TV, or a character of "Self",
    /// "Himself (archive footage)", "Herself - Host" and the like.
    var isSelfAppearance: Bool {
        if !SeerrPersonCredits.selfAppearanceGenres.isDisjoint(with: genreIDs) { return true }
        guard let character else { return false }
        let firstWord = character.trimmingCharacters(in: .whitespaces).lowercased().prefix { $0.isLetter }
        return ["self", "himself", "herself", "themselves", "themself"].contains(String(firstWord))
    }
}

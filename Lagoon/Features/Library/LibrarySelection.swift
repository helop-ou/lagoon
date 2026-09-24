import Foundation

nonisolated enum LibraryMediaKind: String, Codable, CaseIterable, Identifiable {
    case all, movies, shows

    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "Shows")
        }
    }
    var includeTypes: [MediaItemType] {
        switch self {
        case .all: [.movie, .series]
        case .movies: [.movie]
        case .shows: [.series]
        }
    }
    func includes(_ library: LibraryTab) -> Bool {
        switch self {
        case .all: ["movies", "tvshows"].contains(library.collectionType ?? "")
        case .movies: library.collectionType == "movies"
        case .shows: library.collectionType == "tvshows"
        }
    }

    /// A library filter only adds a choice when the media type spans
    /// several libraries.
    func libraryChoices(in libraries: [LibraryTab]) -> [LibraryTab] {
        let matching = libraries.filter { includes($0) }
        let groups = Dictionary(grouping: matching, by: \.collectionType)
        return groups.values.contains { $0.count > 1 } ? matching : []
    }
}

nonisolated enum LibrarySort: String, Codable, CaseIterable, Identifiable {
    case title, recentlyAdded, releaseDate, rating

    var id: Self { self }
    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .recentlyAdded: String(localized: "Recently Added")
        case .releaseDate: String(localized: "Release Date")
        case .rating: String(localized: "Rating")
        }
    }
    var sortBy: String {
        switch self {
        case .title: "SortName"
        case .recentlyAdded: "DateCreated,SortName"
        case .releaseDate: "PremiereDate,SortName"
        case .rating: "CommunityRating,SortName"
        }
    }
    var sortOrder: String { self == .title ? "Ascending" : "Descending,Ascending" }
}

/// A non-overlapping range of production years, shared by movies and series.
/// Persist the first year rather than a localized display label.
nonisolated struct LibraryDecade: RawRepresentable, Codable, Equatable, Hashable, Identifiable {
    let rawValue: Int

    init?(rawValue: Int) {
        guard (0...9990).contains(rawValue), rawValue.isMultiple(of: 10) else { return nil }
        self.rawValue = rawValue
    }

    var id: Int { rawValue }
    var title: String { "\(rawValue)–\(rawValue + 9)" }
    var years: [Int] { Array(rawValue..<(rawValue + 10)) }

    /// Only decades present in the server catalogue, newest first.
    static func choices(years: [Int]) -> [Self] {
        Set(years.filter { (1...9999).contains($0) }
            .compactMap { Self(rawValue: $0 - $0 % 10) })
            .sorted { $0.rawValue > $1.rawValue }
    }
}

nonisolated struct LibraryYearScope: Hashable {
    let kind: LibraryMediaKind
    let libraryID: String?
}

/// The year list from Items/Filters, not the limited page of visible titles.
nonisolated struct LibraryYearFilters: Decodable {
    let years: [Int]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        years = try container.decodeIfPresent([Int].self, forKey: "years") ?? []
    }
}

/// One server query, persisted per account. No title data or credentials.
nonisolated struct LibrarySelection: Codable, Equatable, Hashable {
    var kind: LibraryMediaKind = .all
    var sort: LibrarySort = .title
    var libraryID: String?
    var genre: String?
    var decade: LibraryDecade?
    var unwatchedOnly = false
    var favoritesOnly = false
    var only4K = false

    var yearScope: LibraryYearScope { LibraryYearScope(kind: kind, libraryID: libraryID) }

    var filters: [String] {
        (unwatchedOnly ? ["IsUnplayed"] : []) + (favoritesOnly ? ["IsFavorite"] : [])
    }

    var filterCount: Int {
        [libraryID != nil, genre != nil, decade != nil, unwatchedOnly, favoritesOnly, only4K]
            .filter { $0 }.count
    }

    mutating func selectKind(_ value: LibraryMediaKind, libraries: [LibraryTab]) {
        kind = value
        if let library = libraries.first(where: { $0.id == libraryID }), !value.includes(library) {
            libraryID = nil
        }
        if !libraries.isEmpty { reconcile(libraries: libraries) }
        // Jellyfin stores resolution on playable files, not series folders.
        if value != .movies { only4K = false }
    }

    mutating func reconcile(libraries: [LibraryTab]) {
        if let libraryID, !libraries.contains(where: { $0.id == libraryID && kind.includes($0) }) {
            self.libraryID = nil
        }
        if let library = libraries.first(where: { $0.id == libraryID }),
           kind.libraryChoices(in: libraries).isEmpty {
            // Turn a saved redundant library constraint into its media type,
            // so no invisible filter remains.
            if kind == .all {
                kind = library.collectionType == "movies" ? .movies : .shows
            }
            libraryID = nil
        }
        if kind != .movies { only4K = false }
    }

    mutating func clearFilters() {
        libraryID = nil
        genre = nil
        decade = nil
        unwatchedOnly = false
        favoritesOnly = false
        only4K = false
    }

    mutating func reconcileDecade(available: [LibraryDecade]) {
        if let decade, !available.contains(decade) { self.decade = nil }
    }

    /// Per account; `AccountLocalData` removes it with the account.
    static let keyPrefix = "library.selection."

    static func restore(accountID: String, defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: keyPrefix + accountID),
              let selection = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return selection
    }

    func save(accountID: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.keyPrefix + accountID)
    }
}

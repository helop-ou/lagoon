import Observation
import SwiftUI

nonisolated struct GenreShelfItem: Identifiable {
    let id: String
    let name: String
    let artwork: MediaItem?
}

/// Builds the genre shelf from the genre catalogue and a rating-ranked
/// sample. Each genre's card uses its top-rated item with landscape art.
nonisolated enum GenreShelfResolver {
    static let maximumVisibleGenres = 24

    static func resolve(
        catalog: [MediaGenre],
        candidates: [MediaItem],
        includeTypes: [MediaItemType] = [.movie, .series],
        limit: Int = maximumVisibleGenres
    ) -> [GenreShelfItem] {
        guard limit > 0 else { return [] }

        struct Accumulator {
            var id: String
            var name: String
            var itemCount = 0
            var artwork: MediaItem?
        }

        var byKey: [String: Accumulator] = [:]
        for genre in catalog {
            let name = genre.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            let key = normalized(name)
            byKey[key] = Accumulator(id: genre.id, name: name)
        }

        let rankedCandidates = candidates
            .filter { includeTypes.contains($0.type) }
            .sorted {
                let lhs = $0.communityRating ?? -.infinity
                let rhs = $1.communityRating ?? -.infinity
                if lhs != rhs { return lhs > rhs }
                return ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
            }

        for item in rankedCandidates {
            for rawName in item.genres ?? [] {
                let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = normalized(name)
                var accumulated = byKey[key]
                    ?? Accumulator(id: "derived-\(key)", name: name)
                accumulated.itemCount += 1
                if accumulated.artwork == nil, hasLandscapeArtwork(item) {
                    accumulated.artwork = item
                }
                byKey[key] = accumulated
            }
        }

        return byKey.values
            // Drops stale catalogue genres with no items in the sample.
            .filter { $0.itemCount > 0 }
            // Best represented first, name breaking ties.
            .sorted {
                if $0.itemCount != $1.itemCount { return $0.itemCount > $1.itemCount }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            .prefix(limit)
            .map { GenreShelfItem(id: $0.id, name: $0.name, artwork: $0.artwork) }
    }

    private static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private static func hasLandscapeArtwork(_ item: MediaItem) -> Bool {
        item.imageTags?["Thumb"] != nil || item.backdropImageTags?.isEmpty == false
    }
}

struct GenreRail: View {
    let title: String
    let genres: [GenreShelfItem]
    let includeTypes: [MediaItemType]
    let identifier: String

    var body: some View {
        if !genres.isEmpty {
            RailShelf(title: title) {
                ForEach(genres) { genre in
                    GenreCard(
                        genre: genre,
                        includeTypes: includeTypes,
                        identifier: identifier
                    )
                }
            }
            .accessibilityIdentifier("home.genres.\(identifier)")
        }
    }
}

private struct GenreCard: View {
    let genre: GenreShelfItem
    let includeTypes: [MediaItemType]
    let identifier: String

    var body: some View {
        NavigationLink(value: ContentNavigationRoute.genre(
            name: genre.name,
            includeTypes: includeTypes
        )) {
            ZStack(alignment: .bottomLeading) {
                NamedArtworkBackground(name: genre.name, artwork: genre.artwork)
                GenreCardLabel(name: genre.name)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .cardButtonStyle()
        .accessibilityLabel("\(genre.name) genre")
        .accessibilityIdentifier("home.genre.\(identifier).\(genre.id)")
    }
}

struct GenreLibraryView: View {
    let genre: String
    let includeTypes: [MediaItemType]
    @Environment(SessionStore.self) private var session
    @State private var viewModel = LibraryViewModel()

    private var selection: LibrarySelection {
        var selection = LibrarySelection()
        selection.kind = LibraryMediaKind(includeTypes: includeTypes)
        selection.genre = genre
        return selection
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if viewModel.items.isEmpty, viewModel.isLoading {
                LoadingView()
            } else if viewModel.items.isEmpty, let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await viewModel.loadMore(fetch: session.client.libraryItems) }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                        #if os(tvOS)
                        // A tvOS navigation title floats over the grid;
                        // in the content it scrolls away with the first row.
                        Text(genre)
                            .font(.largeTitle.bold())
                            .accessibilityIdentifier("genre.library.title")
                        #endif

                        PosterGridView(items: viewModel.items, onNearEnd: {
                            Task { await viewModel.loadMore(fetch: session.client.libraryItems) }
                        }) { item in
                            PosterCard(item: item)
                                .itemUserDataMenu(item: item)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                }
                .scrollClipDisabled()
            }
        }
        #if os(iOS)
        .navigationTitle(genre)
        #endif
        .task(id: selection) {
            await viewModel.load(selection: selection, fetch: session.client.libraryItems)
        }
        .accessibilityIdentifier("genre.library")
        .accessibilityValue("\(viewModel.items.count) items")
    }
}

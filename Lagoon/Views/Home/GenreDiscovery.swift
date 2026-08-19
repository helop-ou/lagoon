import Observation
import SwiftUI

nonisolated struct GenreShelfItem: Identifiable {
    let id: String
    let name: String
    let artwork: MediaItem?
}

/// Turns Jellyfin's genre catalogue and one ranked sample of the library
/// into a compact Home shelf. The representative is the highest-rated item
/// in that genre that can actually fill a landscape card.
nonisolated enum GenreShelfResolver {
    static let maximumVisibleGenres = 24

    static func resolve(
        catalog: [MediaGenre],
        candidates: [MediaItem],
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
            .filter { $0.type == .movie || $0.type == .series }
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
            // The ranked sample proves the genre has playable Movie/Series
            // content. This also protects Home from stale catalogue rows.
            .filter { $0.itemCount > 0 }
            // Put the genres that are best represented in this library
            // first, then use a predictable name order to break ties.
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
    let genres: [GenreShelfItem]

    var body: some View {
        if !genres.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Genres")
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Metrics.cardSpacing) {
                        ForEach(genres) { genre in
                            GenreCard(genre: genre)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
            }
            .accessibilityIdentifier("home.genres")
        }
    }
}

private struct GenreCard: View {
    let genre: GenreShelfItem
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationLink {
            GenreLibraryView(genre: genre.name)
        } label: {
            ZStack(alignment: .bottomLeading) {
                background

                LinearGradient(
                    colors: [.clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                Text(genre.name)
                    .font(.title3.bold())
                    .lineLimit(1)
                    .padding(Metrics.Space.xl)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .cardButtonStyle()
        .accessibilityLabel("\(genre.name) genre")
        .accessibilityIdentifier("home.genre.\(genre.id)")
    }

    @ViewBuilder
    private var background: some View {
        if let artwork = genre.artwork {
            CachedAsyncImage(
                url: session.client.imageURL(
                    for: artwork,
                    kind: .thumb,
                    maxWidth: Int(Metrics.landscapeWidth * 1.5)
                ),
                maxPixelSize: Int(Metrics.landscapeWidth * 1.5)
            ) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                fallbackGradient
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipped()
        } else {
            fallbackGradient
        }
    }

    private var fallbackGradient: some View {
        let palettes: [(Color, Color)] = [
            (.indigo.opacity(0.9), .black),
            (.teal.opacity(0.75), Color.lagoonDeep),
            (.purple.opacity(0.8), .black),
            (.orange.opacity(0.65), .black),
            (.blue.opacity(0.75), Color.lagoonDeep),
        ]
        let paletteIndex = genre.name.utf8.reduce(0) {
            ($0 * 31 + Int($1)) % palettes.count
        }
        let palette = palettes[paletteIndex]
        return LinearGradient(
            colors: [palette.0, palette.1],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

@Observable
private final class GenreLibraryViewModel {
    var items: [MediaItem] = []
    var isLoading = false
    var errorMessage: String?

    private var totalCount: Int?
    private let pageSize = 60

    private var hasMore: Bool {
        totalCount.map { items.count < $0 } ?? true
    }

    func loadMore(client: JellyfinClient, genre: String) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await client.items(
                includeTypes: [.movie, .series],
                genres: [genre],
                startIndex: items.count,
                limit: pageSize
            )
            items.append(contentsOf: page.items)
            totalCount = page.totalRecordCount
        } catch {
            errorMessage = "Couldn't load this genre."
        }
        isLoading = false
    }
}

struct GenreLibraryView: View {
    let genre: String
    @Environment(SessionStore.self) private var session
    @State private var viewModel = GenreLibraryViewModel()

    private var columns: [GridItem] { Metrics.posterGridColumns }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.items.isEmpty, viewModel.isLoading {
                LoadingView()
            } else if viewModel.items.isEmpty, let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await viewModel.loadMore(client: session.client, genre: genre) }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                        #if os(tvOS)
                        // A navigation title becomes a floating overlay on
                        // tvOS as the grid scrolls. Keeping the heading in
                        // the scroll content makes it leave with the first
                        // row instead of covering later posters (HEL-84).
                        Text(genre)
                            .font(.largeTitle.bold())
                            .accessibilityIdentifier("genre.library.title")
                        #endif

                        LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                            ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                                PosterCard(item: item)
                                    .itemUserDataMenu(item: item)
                                    .onAppear {
                                        if index >= viewModel.items.count - Metrics.gridColumns * 3 {
                                            Task { await viewModel.loadMore(client: session.client, genre: genre) }
                                        }
                                    }
                            }
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
        .task(id: genre) {
            if viewModel.items.isEmpty {
                await viewModel.loadMore(client: session.client, genre: genre)
            }
        }
        .accessibilityIdentifier("genre.library")
        .accessibilityValue("\(viewModel.items.count) items")
    }
}

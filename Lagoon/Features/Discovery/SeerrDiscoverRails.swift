import Observation
import SwiftUI

/// Per-rail state, so a dead endpoint costs only that rail.
@Observable
private final class SeerrRailLoader {
    var items: [SeerrDiscoverResult] = []
    var isLoading = false
    var didLoad = false
    var errorMessage: String?

    func load(source: SeerrCatalogSource, client: SeerrClient, reset: Bool = false) async {
        guard !isLoading, reset || !didLoad else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let page = try await client.page(for: source)
            guard !Task.isCancelled else { return }
            items = page.results.filter { $0.mediaType == .movie || $0.mediaType == .tv }
            didLoad = true
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A poster shelf that fetches itself when built, so inside a `LazyVStack`
/// a rail below the fold costs nothing until scrolled near.
struct SeerrDiscoverRail: View {
    let source: SeerrCatalogSource
    let refreshGeneration: Int
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var loader = SeerrRailLoader()
    @State private var retryID = 0

    var body: some View {
        Group {
            if !loader.items.isEmpty {
                SeerrMediaRail(
                    title: source.title,
                    items: loader.items,
                    destination: .catalog(source)
                )
            } else if let message = loader.errorMessage {
                placeholder { InlineRetryView(message: message) { retryID += 1 } }
            } else if !loader.didLoad {
                // Also covers "not started": a zero-height row in a LazyVStack
                // is never built, so its `.task` would never run.
                placeholder { ProgressView().accessibilityLabel("Loading \(source.title)") }
            }
            // Loaded but empty draws nothing; an empty watchlist is normal.
        }
        .task(id: "\(source.id):\(seerr.user?.id ?? -1):\(retryID):\(refreshGeneration)") {
            await loader.load(
                source: source,
                client: seerr.client,
                reset: retryID > 0 || refreshGeneration > 0
            )
        }
        .accessibilityIdentifier("seerr.rail.\(source.id)")
    }

    private func placeholder<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            Text(source.title)
                .font(.headline)
            content()
        }
        .padding(.horizontal, Metrics.screenGutter)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
    }

}

/// Like Home's `GenreRail`, over Seerr's genre list and its TMDB backdrops.
struct SeerrGenreRail: View {
    let mediaType: SeerrMediaType
    let title: String
    let refreshGeneration: Int
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var genres: [SeerrGenre] = []
    @State private var didLoad = false

    var body: some View {
        Group {
            if genres.isEmpty, !didLoad {
                // A zero-height row is never built, so its `.task` never runs.
                VStack(alignment: .leading, spacing: Metrics.Space.l) {
                    Text(title)
                        .font(.headline)
                    ProgressView()
                        .accessibilityLabel("Loading \(title)")
                }
                .padding(.horizontal, Metrics.screenGutter)
                .frame(maxWidth: .infinity, minHeight: 180, alignment: .leading)
            } else if !genres.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .padding(.leading, Metrics.screenGutter)

                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: Metrics.cardSpacing) {
                            ForEach(genres) { genre in
                                SeerrGenreCard(genre: genre, mediaType: mediaType)
                            }
                        }
                        .padding(.horizontal, Metrics.screenGutter)
                        .padding(.top, Metrics.railTopPadding)
                        .padding(.bottom, Metrics.railBottomPadding)
                    }
                }
            }
        }
        .task(id: "genres:\(mediaType.rawValue):\(seerr.user?.id ?? -1):\(refreshGeneration)") {
            guard refreshGeneration > 0 || !didLoad else { return }
            // No retry control: a failed genre shelf just does not appear.
            do {
                let refreshed = try await seerr.client.genres(mediaType)
                guard !Task.isCancelled else { return }
                genres = refreshed
                didLoad = true
            } catch is CancellationError {
            } catch {
                // A failed refresh keeps the existing shelf.
                if genres.isEmpty { didLoad = true }
            }
        }
        .accessibilityIdentifier("seerr.genres.\(mediaType.rawValue)")
    }
}

private struct SeerrGenreCard: View {
    let genre: SeerrGenre
    let mediaType: SeerrMediaType

    var body: some View {
        NavigationLink(
            value: SeerrNavigationRoute.catalog(
                .genre(mediaType, id: genre.id, name: genre.name)
            )
        ) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: backdropURL, maxPixelSize: Int(Metrics.landscapeWidth * 2)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.white.opacity(0.06)
                }
                .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
                .clipped()

                // The name has to hold over whatever still sits behind it.
                LinearGradient(
                    colors: [.black.opacity(0.85), .black.opacity(0.1)],
                    startPoint: .bottom,
                    endPoint: .top
                )

                Text(genre.name)
                    .font(.headline)
                    .padding(Metrics.Space.l)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
        .cardButtonStyle()
        .accessibilityLabel(genre.name)
        .accessibilityIdentifier("seerr.genre.\(genre.id)")
    }
}

private extension SeerrGenreCard {
    /// Deterministic, so the shelf does not reshuffle on every visit.
    var backdropURL: URL? {
        guard !genre.backdrops.isEmpty else { return nil }
        let path = genre.backdrops[abs(genre.id) % genre.backdrops.count]
        return SeerrClient.imageURL(path: path, width: Int(Metrics.landscapeWidth * 2))
    }
}

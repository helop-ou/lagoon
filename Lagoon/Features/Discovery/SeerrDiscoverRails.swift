import Observation
import SwiftUI

/// One rail's worth of state. Each rail owns its own, so a dead endpoint
/// costs that rail and nothing else — the whole page used to be discarded on
/// any single failure, which does not survive having eight of them.
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

/// A poster shelf fed by one `SeerrCatalogSource`, fetching itself when it is
/// built rather than as part of one page-wide load. Inside a `LazyVStack`
/// that means a rail below the fold costs nothing until it is scrolled near,
/// so adding rows does not slow the screen down.
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
                // Covers "loading" *and* "not started yet". A rail that draws
                // nothing has no height, and a zero-height row inside a
                // LazyVStack is never realised — so its `.task` never runs and
                // it stays empty forever. The placeholder is what gives the
                // row enough size to be built in the first place.
                placeholder { ProgressView().accessibilityLabel("Loading \(source.title)") }
            }
            // A rail that loaded and came back empty draws nothing at all.
            // An empty watchlist is the ordinary case, not a fault.
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

/// The genre browse shelf, built like Home's `GenreRail` but over Seerr's own
/// genre list, which ships its own TMDB backdrops rather than needing a
/// representative picked out of the library.
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
                // Same reason as the poster rails: a row with no height is
                // never built, so its `.task` never runs.
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
            // A genre shelf that will not load is not worth a retry control
            // on a browse screen; the rail simply does not appear.
            do {
                let refreshed = try await seerr.client.genres(mediaType)
                guard !Task.isCancelled else { return }
                genres = refreshed
                didLoad = true
            } catch is CancellationError {
            } catch {
                // Preserve an existing shelf during an opportunistic refresh.
                // The first load keeps the old no-row failure behavior.
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
    /// Deterministic rather than random: the same genre keeps the same
    /// picture between launches, so the shelf does not reshuffle itself
    /// every time Discover is opened.
    var backdropURL: URL? {
        guard !genre.backdrops.isEmpty else { return nil }
        let path = genre.backdrops[abs(genre.id) % genre.backdrops.count]
        return SeerrClient.imageURL(path: path, width: Int(Metrics.landscapeWidth * 2))
    }
}

import SwiftUI

/// One collection as Home draws it: the collection itself, how much is in it,
/// and the artwork the card should use.
nonisolated struct CollectionShelfItem: Identifiable, Equatable {
    /// The collection's own id, so the card routes to its page.
    var id: String { collection.id }
    let collection: MediaItem
    let titleCount: Int
    /// What the card paints. The collection's own artwork where it has some,
    /// and otherwise one of the titles inside it — see `artworkSource`.
    let artwork: MediaItem?

    var name: String { collection.name ?? "" }
}

/// Which collections are worth a row, in what order, and what they look like.
///
/// **A library's collection list is mostly stubs.** Jellyfin's metadata
/// scrape creates a collection for a film's whole franchise the moment you
/// own one entry in it, so the reference library reports 173 collections of
/// which 35 hold anything and 18 hold more than one title. Every rule here
/// exists because of that shape: unfiltered, this row is a hundred and
/// seventy-three empty franchises in alphabetical order.
nonisolated enum CollectionShelf {
    /// Settings, Home Rows. A stable string for the same reason the curated
    /// rows use them: it is persisted per account, and renaming it would
    /// silently re-enable a row someone had turned off.
    static let rowID = "lagoon.collections"

    /// A collection holding one title is that title with a longer name — the
    /// card would open a page listing the film you were already looking at.
    /// Two is the point at which "collection" starts meaning something.
    static let minimumTitles = 2

    /// Same ceiling as the curated rows. Beyond a screen or two of sideways
    /// scrolling a shelf stops being browsable and the Collections tab this
    /// row stands in for would be the honest answer.
    static let maximumVisible = 16

    /// Whether a card can be painted from this item without borrowing.
    ///
    /// Landscape specifically: Home's rows are 16:9 and a collection's poster
    /// is not one. Collections are far likelier to have a poster than a thumb
    /// — 11 of the reference library's 18 real collections have a Primary and
    /// only 7 have anything landscape — which is exactly why the fallback
    /// below exists rather than a poster-shaped exception to the row.
    static func hasLandscapeArtwork(_ item: MediaItem) -> Bool {
        item.imageTags?["Thumb"] != nil || item.backdropImageTags?.isEmpty == false
    }

    /// The collections that earn a card, biggest first.
    ///
    /// Size order rather than alphabetical: a five-film franchise is a more
    /// interesting thing to be offered than the first collection whose name
    /// begins with A, and the name breaks ties so the row does not reshuffle
    /// between loads.
    static func ranked(_ collections: [MediaItem], limit: Int = maximumVisible) -> [MediaItem] {
        collections
            .filter { ($0.childCount ?? 0) >= minimumTitles }
            .sorted {
                let lhs = $0.childCount ?? 0
                let rhs = $1.childCount ?? 0
                if lhs != rhs { return lhs > rhs }
                return ($0.name ?? "").localizedStandardCompare($1.name ?? "") == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    /// The title inside a collection whose artwork can stand in for it.
    ///
    /// The first one in release order that has any: a franchise's first film
    /// is the one whose artwork reads as the franchise. Nil when nothing
    /// inside has landscape artwork either, and the card falls back to type
    /// on a gradient.
    static func artworkSource(from contents: [MediaItem]) -> MediaItem? {
        contents.first(where: hasLandscapeArtwork)
    }

    /// Assembles the shelf. `borrowedArtwork` is keyed by collection id and
    /// only consulted for the collections that need it, so a caller that
    /// fetched nothing still gets a usable row.
    static func shelf(
        _ collections: [MediaItem],
        borrowedArtwork: [String: MediaItem] = [:]
    ) -> [CollectionShelfItem] {
        collections.map { collection in
            CollectionShelfItem(
                collection: collection,
                titleCount: collection.childCount ?? 0,
                artwork: hasLandscapeArtwork(collection)
                    ? collection
                    : borrowedArtwork[collection.id]
            )
        }
    }

    /// "5 titles". Deliberately not "5 movies": a collection can hold series
    /// as well, and counting the contents is not worth a request to find out
    /// what to call them.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 title" : "\(count) titles"
    }

    /// "2011 – 2024", or a single year when a franchise landed in one, or
    /// nothing at all when the server dated none of it.
    static func yearsLabel(_ items: [MediaItem]) -> String? {
        let years = items.compactMap(\.productionYear).sorted()
        guard let first = years.first, let last = years.last else { return nil }
        return first == last ? String(first) : "\(first) – \(last)"
    }

    /// The genres a collection is about, from its own metadata where the
    /// scrape supplied any and from its contents where it did not — 7 of the
    /// reference library's 18 real collections carry no genres of their own.
    ///
    /// Ordered by how much of the collection shares them, so the first two
    /// describe the franchise rather than one entry in it.
    static func genres(of collection: MediaItem, contents: [MediaItem], limit: Int = 3) -> [String] {
        if let own = collection.genres, !own.isEmpty {
            return Array(own.prefix(limit))
        }
        var counts: [String: Int] = [:]
        for genre in contents.flatMap({ $0.genres ?? [] }) {
            counts[genre, default: 0] += 1
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }
}

/// The Collections row (HEL-122).
///
/// Its own view rather than a `MediaRail` because a collection card is not a
/// title card: the artwork is usually borrowed from one film inside, so
/// without the collection's name written across it the *Greenland Collection*
/// card is indistinguishable from the film *Greenland*.
struct CollectionRail: View {
    let title: String
    let collections: [CollectionShelfItem]

    var body: some View {
        if !collections.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Metrics.cardSpacing) {
                        ForEach(collections) { collection in
                            CollectionCard(collection: collection)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
            }
            .accessibilityIdentifier("home.collections")
        }
    }
}

private struct CollectionCard: View {
    let collection: CollectionShelfItem
    @Environment(SessionStore.self) private var session

    var body: some View {
        NavigationLink(value: ContentNavigationRoute.item(collection.collection)) {
            ZStack(alignment: .bottomLeading) {
                background

                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )

                VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                    Text(collection.name)
                        .font(.title3.bold())
                        .lineLimit(2)
                    Text(CollectionShelf.countLabel(collection.titleCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Metrics.Space.xl)
            }
            .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
        }
        .cardButtonStyle()
        .accessibilityLabel("\(collection.name), \(CollectionShelf.countLabel(collection.titleCount))")
        .accessibilityIdentifier("home.collection.\(collection.id)")
    }

    @ViewBuilder
    private var background: some View {
        if let artwork = collection.artwork {
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

    /// Same trick the genre cards use: a stable colour per name, so a
    /// collection with no artwork anywhere still gets a card of its own
    /// rather than one more grey rectangle in a row of them.
    private var fallbackGradient: some View {
        let palettes: [(Color, Color)] = [
            (.indigo.opacity(0.9), .black),
            (.teal.opacity(0.75), Color.lagoonNavy),
            (.purple.opacity(0.8), .black),
            (.orange.opacity(0.65), .black),
            (.blue.opacity(0.75), Color.lagoonNavy),
        ]
        let paletteIndex = collection.name.utf8.reduce(0) {
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

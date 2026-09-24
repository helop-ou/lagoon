import SwiftUI

/// One collection as Home draws it.
nonisolated struct CollectionShelfItem: Identifiable, Equatable {
    var id: String { collection.id }
    let collection: MediaItem
    let titleCount: Int
    /// The collection's own artwork, or a title's from inside (see `artworkSource`).
    let artwork: MediaItem?

    var name: String { collection.name ?? "" }
}

/// Which collections get a card, in what order, and with what artwork.
///
/// Most collections are stubs: Jellyfin creates one per franchise as soon as
/// you own one film in it (173 on the reference library, 18 with more than
/// one title). These rules filter that down.
nonisolated enum CollectionShelf {
    /// Persisted per account; renaming would re-enable a hidden row.
    static let rowID = "lagoon.collections"

    /// A one-title collection is just that title.
    static let minimumTitles = 2

    static let maximumVisible = 16

    /// Landscape only, since Home's cards are 16:9. Most collections have a
    /// poster but no landscape art, hence the borrowed-artwork fallback.
    static func hasLandscapeArtwork(_ item: MediaItem) -> Bool {
        item.imageTags?["Thumb"] != nil || item.backdropImageTags?.isEmpty == false
    }

    /// Collections that earn a card, biggest first, name breaking ties so
    /// the row is stable between loads.
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

    /// The first title in release order with landscape art, or nil (the
    /// card then uses a gradient).
    static func artworkSource(from contents: [MediaItem]) -> MediaItem? {
        contents.first(where: hasLandscapeArtwork)
    }

    /// `borrowedArtwork` is keyed by collection id and may be empty.
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

    /// "5 titles", not "movies": a collection can hold series too.
    static func countLabel(_ count: Int) -> String {
        count == 1 ? "1 title" : "\(count) titles"
    }

    /// "2011 – 2024", a single year, or nil when nothing is dated.
    static func yearsLabel(_ items: [MediaItem]) -> String? {
        let years = items.compactMap(\.productionYear).sorted()
        guard let first = years.first, let last = years.last else { return nil }
        return first == last ? String(first) : "\(first) – \(last)"
    }

    /// The collection's own genres, or else its contents' genres, most
    /// shared first. Many collections carry none of their own.
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

/// The Collections row. Not a `MediaRail`, because a card with borrowed
/// artwork needs a label to tell the collection from the film.
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
                // Or the focus halo is cut off square at the rail edge.
                .scrollClipDisabled()
            }
            .accessibilityIdentifier("home.collections")
        }
    }
}

/// The name sits under the artwork, not over it: collection art often has
/// the name painted in already, and a caption can wrap instead of truncating.
private struct CollectionCard: View {
    @Environment(\.displayScale) private var displayScale
    let collection: CollectionShelfItem
    @Environment(SessionStore.self) private var session

    var body: some View {
        // Room for the `.card` focus lift, which scales the art about 10%.
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            NavigationLink(value: ContentNavigationRoute.item(collection.collection)) {
                background
                    .frame(width: Metrics.landscapeWidth, height: Metrics.landscapeHeight)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .accessibilityLabel("\(collection.name), \(CollectionShelf.countLabel(collection.titleCount))")
            .accessibilityIdentifier("home.collection.\(collection.id)")

            caption
        }
        .frame(width: Metrics.landscapeWidth)
    }

    /// Fixed height keeps one- and two-line names on the same baseline.
    private var caption: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
            Text(collection.name)
                .font(.caption.weight(.medium))
                .lineLimit(2)
            Text(CollectionShelf.countLabel(collection.titleCount))
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(
            width: Metrics.landscapeWidth,
            height: Metrics.landscapeCaptionHeight,
            alignment: .topLeading
        )
    }

    @ViewBuilder
    private var background: some View {
        if let artwork = collection.artwork {
            CachedAsyncImage(
                url: session.client.imageURL(
                    for: artwork,
                    kind: .thumb,
                    maxWidth: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
                ),
                maxPixelSize: ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
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

    /// No artwork anywhere: a gradient picked from the name, not plain grey.
    private var fallbackGradient: some View {
        let palettes: [(Color, Color)] = [
            (Theme.accent.opacity(0.9), Theme.ground),
            (Theme.palette.glowDepth.opacity(0.9), Theme.background),
            (Theme.ground.opacity(0.9), Theme.palette.glowDepth),
            (Theme.accent.opacity(0.65), Theme.background),
            (Theme.palette.glowDepth.opacity(0.75), Theme.ground),
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

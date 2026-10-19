import SwiftUI

/// A Home Screen Sections row of titles from Sonarr, Radarr or Seerr. None
/// is in the library, so a card opens the title's Seerr page, as Discover's
/// do, once `HomeViewModel` has found it in Seerr, and nothing until then.
struct ExternalSectionRail: View {
    let title: String
    let items: [JellyfinClient.ExternalSectionItem]
    /// Seerr's record of each title, by item id.
    let seerrTitles: [String: ExternalSeerrTitle]

    var body: some View {
        if !items.isEmpty {
            RailShelf(title: title) {
                ForEach(items) { item in
                    ExternalSectionCard(item: item, seerrTitle: seerrTitles[item.id])
                }
            }
        }
    }
}

/// 16:9 like Home's other rails: Seerr's backdrop, or the plugin's poster
/// cropped when Seerr has no record of the title.
private struct ExternalSectionCard: View {
    let item: JellyfinClient.ExternalSectionItem
    let seerrTitle: ExternalSeerrTitle?
    @Environment(\.jellyfinClient) private var client
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        link {
            LandscapeArtwork(
                imageURL: imageURL,
                maxPixelSize: pixelWidth,
                showsMetadata: true,
                progress: nil
            ) {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(item.title)
                        .font(.footnote.bold())
                        .lineLimit(1)
                    if let subtitle = item.subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .cardButtonStyle()
        .artworkFocusHue(url: imageURL, cornerRadius: Metrics.cardArtRadius)
        .accessibilityLabel([item.title, item.subtitle].compactMap(\.self).joined(separator: ", "))
        .accessibilityIdentifier("home.external.\(item.id)")
    }

    private var pixelWidth: Int {
        ArtworkSizing.pixels(for: Metrics.landscapeWidth, displayScale: displayScale)
    }

    private var imageURL: URL? {
        SeerrClient.imageURL(path: seerrTitle?.backdropPath, width: pixelWidth)
            ?? item.posterPath.flatMap { client?.serverRelativeURL($0) }
    }

    /// A button that does nothing when there is no page: tvOS can only
    /// scroll a rail through focusable cards.
    @ViewBuilder
    private func link(@ViewBuilder label: () -> some View) -> some View {
        if let seerrTitle {
            NavigationLink(
                value: SeerrNavigationRoute.media(id: seerrTitle.id, type: seerrTitle.mediaType),
                label: label
            )
        } else {
            Button(action: {}, label: label)
        }
    }
}

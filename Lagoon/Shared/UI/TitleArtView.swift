import SwiftUI

/// The title as its logo when the server has one, otherwise as type.
struct TitleArtView: View {
    @Environment(\.displayScale) private var displayScale
    let item: MediaItem
    var alignment: HorizontalAlignment = .leading

    @Environment(\.jellyfinClient) private var client

    var body: some View {
        TitleArtImage(
            url: client?.imageURL(for: item, kind: .logo, maxWidth: ArtworkSizing.pixels(for: Metrics.logoMaxWidth, displayScale: displayScale)),
            title: item.name ?? "",
            maxHeight: Metrics.logoMaxHeight,
            alignment: alignment
        )
    }
}

/// `TitleArtView` for sources that resolve their own artwork URL, such as
/// Seerr (which has no logos, so it always shows type).
struct TitleArtImage: View {
    @Environment(\.displayScale) private var displayScale
    let url: URL?
    let title: String
    var maxHeight: CGFloat = Metrics.logoMaxHeight
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        artwork
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            CachedAsyncImage(url: url, maxPixelSize: ArtworkSizing.pixels(for: Metrics.logoMaxWidth, displayScale: displayScale)) { image in
                image
                    .resizable()
                    .scaledToFit()
            } placeholder: {
                // Type, not a box: reserving the logo's height leaves a hole.
                titleText
            }
            .frame(maxWidth: Metrics.logoMaxWidth, maxHeight: maxHeight, alignment: Alignment(horizontal: alignment, vertical: .center))
        } else {
            titleText
        }
    }

    private var titleText: some View {
        Text(title)
            .font(.largeTitle.bold())
            #if os(tvOS)
            .lineLimit(2)
            #endif
            .multilineTextAlignment(alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading))
            .fixedSize(horizontal: false, vertical: true)
    }
}

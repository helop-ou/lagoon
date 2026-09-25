import SwiftUI

struct SeerrMediaCard: View {
    let item: SeerrDiscoverResult
    let layout = PosterLayout()

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            NavigationLink(value: route) {
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(
                        url: SeerrClient.imageURL(path: item.posterPath, width: layout.imageWidth),
                        maxPixelSize: layout.imageSize
                    ) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            Color.white.opacity(0.07)
                            Text(item.displayTitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(Metrics.Space.m)
                        }
                    }
                    .frame(width: layout.width, height: layout.height)
                    .clipped()

                    if let status = visibleStatus {
                        Text(status.title)
                            .font(.caption2.bold())
                            .padding(.horizontal, Metrics.Space.s)
                            .padding(.vertical, Metrics.Space.xs)
                            .background(.regularMaterial, in: Capsule())
                            .padding(Metrics.Space.s)
                    }
                }
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .artworkFocusHue(
                url: SeerrClient.imageURL(path: item.posterPath, width: layout.imageWidth),
                cornerRadius: Metrics.cardArtRadius
            )
            .accessibilityLabel(item.displayTitle)
            .accessibilityValue(visibleStatus?.title ?? "Not Requested")
            .accessibilityIdentifier("seerr.media.\(mediaType.rawValue).\(item.id)")

            VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                Text(item.displayTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(layout.captionLines)
                if let year = item.year {
                    Text(year)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: layout.width, alignment: .leading)
            .frame(minHeight: layout.captionHeight, alignment: .topLeading)
        }
        .frame(width: layout.width)
    }

    private var mediaType: SeerrMediaType {
        item.mediaType == .tv ? .tv : .movie
    }

    private var route: SeerrNavigationRoute {
        .media(id: item.id, type: mediaType)
    }

    /// No badge for unrequested or deleted titles; blocklisted ones get one.
    private var visibleStatus: SeerrAvailabilityStatus? {
        let status = item.mediaInfo?.availability ?? .unknown
        return status.allowsRequesting ? nil : status
    }
}

struct SeerrMediaRail: View {
    let title: String
    let items: [SeerrDiscoverResult]
    /// Set for rails backed by a paged list: a last card opens the full list.
    var destination: SeerrNavigationRoute?

    var body: some View {
        RailShelf(
            title: title,
            destination: destination,
            seeAllIdentifier: "seerr.seeAll",
            showsSeeAllCard: !requestableItems.isEmpty,
            alignment: .top
        ) {
            ForEach(requestableItems) { item in
                SeerrMediaCard(item: item)
            }
        }
    }

    private var requestableItems: [SeerrDiscoverResult] {
        items.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }
}

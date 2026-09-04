import SwiftUI

struct SeerrMediaCard: View {
    let item: SeerrDiscoverResult

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            NavigationLink(value: route) {
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(
                        url: SeerrClient.imageURL(path: item.posterPath, width: 500),
                        maxPixelSize: Int(Metrics.posterHeight)
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
                    .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
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
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            .cardButtonStyle()
            .artworkFocusHue(
                url: SeerrClient.imageURL(path: item.posterPath, width: 500),
                cornerRadius: Metrics.cardArtRadius
            )
            .accessibilityLabel(item.displayTitle)
            .accessibilityValue(visibleStatus?.title ?? "Not Requested")
            .accessibilityIdentifier("seerr.media.\(mediaType.rawValue).\(item.id)")

            VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                Text(item.displayTitle)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                if let year = item.year {
                    Text(year)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: Metrics.posterWidth, height: Metrics.posterCaptionHeight, alignment: .topLeading)
        }
        .frame(width: Metrics.posterWidth)
    }

    private var mediaType: SeerrMediaType {
        item.mediaType == .tv ? .tv : .movie
    }

    private var route: SeerrNavigationRoute {
        .media(id: item.id, type: mediaType)
    }

    /// No badge for a title nobody has asked for yet — including one whose
    /// media record was deleted, which reads the same way to a viewer. A
    /// blocklisted title *does* get one, since "you cannot have this" is
    /// worth saying (HEL-115).
    private var visibleStatus: SeerrAvailabilityStatus? {
        let status = item.mediaInfo?.availability ?? .unknown
        return status.allowsRequesting ? nil : status
    }
}

struct SeerrMediaRail: View {
    let title: String
    let items: [SeerrDiscoverResult]
    /// When the rail is backed by a paged list, a card at the end of it opens
    /// the full list. Every Discover rail is (HEL-114); the search result
    /// rails are not.
    var destination: SeerrNavigationRoute?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, Metrics.screenGutter)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(requestableItems) { item in
                        SeerrMediaCard(item: item)
                    }
                    if let destination, !requestableItems.isEmpty {
                        SeerrSeeAllCard(destination: destination, title: title)
                    }
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, Metrics.railTopPadding)
                .padding(.bottom, Metrics.railBottomPadding)
            }
            .scrollClipDisabled()
        }
    }

    private var requestableItems: [SeerrDiscoverResult] {
        items.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }
}

/// Ends a rail rather than sitting above it. A focusable heading put a stop
/// between every pair of rails, so moving down the page meant passing through
/// one for each — clunky on a remote (Jaagop). Here it is just the last thing
/// in the row you were already scrolling.
private struct SeerrSeeAllCard: View {
    let destination: SeerrNavigationRoute
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            NavigationLink(value: destination) {
                ZStack {
                    Color.white.opacity(0.07)
                    VStack(spacing: Metrics.Space.m) {
                        Image(systemName: "arrow.forward")
                            .font(.title2)
                        Text("See All")
                            .font(.callout.weight(.medium))
                    }
                }
                .frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            // The system card treatment, like every other card in the rail:
            // the focus visual is never ours to draw.
            .cardButtonStyle()
            .accessibilityLabel("See all \(title)")
            .accessibilityIdentifier("seerr.seeAll")

            // Keeps the row's baseline: the poster cards below reserve this
            // much for their title and year.
            Color.clear
                .frame(width: Metrics.posterWidth, height: Metrics.posterCaptionHeight)
        }
        .frame(width: Metrics.posterWidth)
    }
}

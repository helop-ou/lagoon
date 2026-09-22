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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                #if os(iOS)
                if let destination {
                    Spacer()
                    NavigationLink("See All", value: destination)
                        .font(.callout)
                        .accessibilityLabel("See all \(title)")
                }
                #endif
            }
            .padding(.horizontal, Metrics.screenGutter)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(requestableItems) { item in
                        SeerrMediaCard(item: item)
                    }
                    #if os(tvOS)
                    if let destination, !requestableItems.isEmpty {
                        RailSeeAllCard(destination: destination, title: title, identifier: "seerr.seeAll")
                    }
                    #endif
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

/// Ends a rail rather than heading it: a focusable heading adds a focus
/// stop between every pair of rails.
struct RailSeeAllCard<Route: Hashable>: View {
    let destination: Route
    let title: String
    var identifier = "rail.seeAll"
    let layout = PosterLayout()

    var body: some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
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
                .frame(width: layout.width, height: layout.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))
            }
            // The system draws the focus visual, never us.
            .cardButtonStyle()
            .accessibilityLabel("See all \(title)")
            .accessibilityIdentifier(identifier)

            // Matches the poster cards' caption space to keep the baseline.
            Color.clear
                .frame(width: layout.width, height: layout.captionHeight)
        }
        .frame(width: layout.width)
    }
}

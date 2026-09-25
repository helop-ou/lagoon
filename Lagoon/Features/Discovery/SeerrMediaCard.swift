import SwiftUI

struct SeerrMediaCard: View {
    let item: SeerrDiscoverResult
    let layout = PosterLayout()

    var body: some View {
        PosterCardShell(
            route: route,
            imageURL: SeerrClient.imageURL(path: item.posterPath, width: layout.imageWidth),
            maxPixelSize: layout.imageSize,
            title: item.displayTitle,
            subtitle: item.year,
            accessibilityLabel: item.displayTitle,
            accessibilityValue: visibleStatus?.title ?? "Not Requested",
            accessibilityIdentifier: "seerr.media.\(mediaType.rawValue).\(item.id)"
        ) {
            if let visibleStatus {
                StatusCapsule { Text(visibleStatus.title) }
            }
        }
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

/// The material pill for a Seerr title's or request's status. Self-positions
/// at the artwork's top-trailing corner, so it works inside `PosterCardShell`
/// regardless of the shell's own stacking alignment.
struct StatusCapsule<Label: View>: View {
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.caption2.bold())
            .padding(.horizontal, Metrics.Space.s)
            .padding(.vertical, Metrics.Space.xs)
            .background(.regularMaterial, in: Capsule())
            .padding(Metrics.Space.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
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

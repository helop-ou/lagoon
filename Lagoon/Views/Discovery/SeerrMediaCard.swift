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

    private var visibleStatus: SeerrAvailabilityStatus? {
        let status = item.mediaInfo?.availability ?? .unknown
        return status == .unknown || status == .deleted ? nil : status
    }
}

struct SeerrMediaRail: View {
    let title: String
    let items: [SeerrDiscoverResult]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, Metrics.screenGutter)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: Metrics.cardSpacing) {
                    ForEach(requestableItems) { item in
                        SeerrMediaCard(item: item)
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

import SwiftUI

enum RailStyle {
    case poster
    case landscape
}

/// The shared shape for every horizontal rail: heading, the iOS "See All"
/// link when there is a destination, and the scrolling shelf beneath it.
/// The asymmetric top/bottom padding inside the ScrollView is the room the
/// system focus lift needs; `.scrollClipDisabled()` keeps lifted cards from
/// being clipped at rail boundaries. `Destination == Never` (the default
/// initializer below) drops the "See All" affordance entirely for rails that
/// never navigate to a fuller list.
struct RailShelf<Destination: Hashable, Content: View>: View {
    let title: String
    let destination: Destination?
    let seeAllIdentifier: String
    /// tvOS only: some callers already know their content is empty and skip
    /// the trailing card even though a destination exists.
    let showsSeeAllCard: Bool
    let alignment: VerticalAlignment
    let spacing: CGFloat
    let content: () -> Content

    init(
        title: String,
        destination: Destination?,
        seeAllIdentifier: String = "rail.seeAll",
        showsSeeAllCard: Bool = true,
        alignment: VerticalAlignment = .center,
        spacing: CGFloat = Metrics.cardSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.destination = destination
        self.seeAllIdentifier = seeAllIdentifier
        self.showsSeeAllCard = showsSeeAllCard
        self.alignment = alignment
        self.spacing = spacing
        self.content = content
    }

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
                LazyHStack(alignment: alignment, spacing: spacing) {
                    content()
                    #if os(tvOS)
                    if let destination, showsSeeAllCard {
                        RailSeeAllCard(destination: destination, title: title, identifier: seeAllIdentifier)
                    }
                    #endif
                }
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.top, Metrics.railTopPadding)
                .padding(.bottom, Metrics.railBottomPadding)
            }
            // Or the focus halo is cut off square at the rail edge.
            .scrollClipDisabled()
        }
    }
}

extension RailShelf where Destination == Never {
    /// For rails with no "See All" destination at all.
    init(
        title: String,
        alignment: VerticalAlignment = .center,
        spacing: CGFloat = Metrics.cardSpacing,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.init(
            title: title,
            destination: nil,
            alignment: alignment,
            spacing: spacing,
            content: content
        )
    }
}

struct MediaRail: View {
    let title: String
    let items: [MediaItem]
    var style: RailStyle = .poster
    /// For Continue Watching and Next Up, which need episode context.
    var showsLandscapeMetadata = false
    var playAction: ((MediaItem) -> Void)?
    /// Lets a card's watched/favourite menu re-fetch the list it sits in.
    var onUserDataChange: (() async -> Void)?
    var destination: ContentNavigationRoute?

    var body: some View {
        if !items.isEmpty {
            RailShelf(title: title, destination: destination) {
                ForEach(items) { item in
                    Group {
                        switch style {
                        case .poster:
                            PosterCard(item: item)
                        case .landscape:
                            if let playAction {
                                LandscapeCard(item: item, showsMetadata: showsLandscapeMetadata) {
                                    playAction(item)
                                }
                            } else {
                                LandscapeCard(item: item, showsMetadata: showsLandscapeMetadata)
                            }
                        }
                    }
                    .itemUserDataMenu(item: item, onChange: onUserDataChange)
                }
            }
        }
    }
}

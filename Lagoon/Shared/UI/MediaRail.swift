import SwiftUI

enum RailStyle {
    case poster
    case landscape
}

/// Horizontal content shelf. The asymmetric top/bottom padding inside the
/// ScrollView is the room the system focus lift needs; the page-level
/// ScrollView must carry `.scrollClipDisabled()` so lifted cards aren't
/// clipped at rail boundaries.
struct MediaRail: View {
    let title: String
    let items: [MediaItem]
    var style: RailStyle = .poster
    /// Continue Watching and Next Up need episode context. Other landscape
    /// shelves should let their artwork stand on its own.
    var showsLandscapeMetadata = false
    var playAction: ((MediaItem) -> Void)?
    /// Lets a card's watched/favourite menu re-fetch the list it sits in.
    var onUserDataChange: (() async -> Void)?
    var destination: ContentNavigationRoute?

    var body: some View {
        if !items.isEmpty {
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
                    LazyHStack(spacing: Metrics.cardSpacing) {
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
                        #if os(tvOS)
                        if let destination {
                            RailSeeAllCard(destination: destination, title: title)
                        }
                        #endif
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
                // The rail's own ScrollView clips to its bounds, which cut the
                // focus halo off square at the rail edge. The page-level
                // ScrollView already does this for the lift; the shelf needs
                // it too, or anything that bleeds past a card is sliced.
                .scrollClipDisabled()
            }
        }
    }
}

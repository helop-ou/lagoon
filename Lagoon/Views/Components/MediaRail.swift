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
    var playAction: ((MediaItem) -> Void)?
    /// Lets a card's watched/favourite menu re-fetch the list it sits in.
    var onUserDataChange: (() async -> Void)?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Metrics.cardSpacing) {
                        ForEach(items) { item in
                            Group {
                                switch style {
                                case .poster:
                                    PosterCard(item: item)
                                case .landscape:
                                    LandscapeCard(item: item) {
                                        playAction?(item)
                                    }
                                }
                            }
                            .itemUserDataMenu(item: item, onChange: onUserDataChange)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
            }
        }
    }
}

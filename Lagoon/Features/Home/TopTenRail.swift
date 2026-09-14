import SwiftUI

/// A ranked Home shelf with an oversized number beside each title, so the
/// order is visible at a glance instead of being hidden in the row's data.
struct TopTenRail: View {
    let title: String
    let items: [MediaItem]
    var onUserDataChange: (() async -> Void)?

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, Metrics.screenGutter)

                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: Metrics.cardSpacing) {
                        ForEach(Array(items.prefix(10).enumerated()), id: \.element.id) { offset, item in
                            rankedCard(item: item, rank: offset + 1)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func rankedCard(item: MediaItem, rank: Int) -> some View {
        HStack(alignment: .bottom, spacing: -Metrics.topTenRankOverlap) {
            Text(String(rank))
                .font(Typography.topTenRank)
                .foregroundStyle(Theme.accent.opacity(0.7))
                .frame(width: Metrics.topTenRankWidth, alignment: .trailing)
                .accessibilityHidden(true)

            LandscapeCard(item: item)
        }
        .itemUserDataMenu(item: item, onChange: onUserDataChange)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(rank), \(item.railTitle)")
    }
}

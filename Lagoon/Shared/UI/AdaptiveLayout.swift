import SwiftUI

/// Actions keep their natural label width, then stack when a phone cannot
/// fit them. tvOS retains its horizontal focus geometry.
struct AdaptiveActionStack<Content: View>: View {
    var spacing: CGFloat = Metrics.Space.m
    @ViewBuilder let content: Content

    var body: some View {
        #if os(tvOS)
        HStack(spacing: spacing) { content }
        #else
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
                .fixedSize()
            VStack(alignment: .leading, spacing: spacing) { content }
        }
        #endif
    }
}

/// Wrap metadata between tokens, but allow a token longer than the viewport
/// to wrap internally too. Unlike fixed-size HStacks, this also handles
/// translated strings and accessibility text sizes.
struct MetadataFlowLayout: Layout {
    var spacing: CGFloat = Metrics.Space.m

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (index, frame) in arrangement.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat?) -> (size: CGSize, frames: [CGRect]) {
        let available = max(0, width ?? .infinity)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let ideal = subview.sizeThatFits(.unspecified)
            let size = subview.sizeThatFits(ProposedViewSize(width: min(ideal.width, available), height: nil))
            if x > 0, x + size.width > available {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width ?? usedWidth, height: y + rowHeight), frames)
    }
}

/// Cards and their grids must scale together; scaling just the caption
/// leaves accessibility text crowded into a three-column phone grid.
struct PosterLayout: DynamicProperty {
    @ScaledMetric(relativeTo: .caption) private var scaledWidth = Metrics.posterWidth
    @ScaledMetric(relativeTo: .caption) private var scaledCaptionHeight = Metrics.posterCaptionHeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale

    var width: CGFloat {
        #if os(tvOS)
        Metrics.posterWidth
        #else
        min(scaledWidth, Metrics.accessibilityPosterWidth)
        #endif
    }

    var height: CGFloat { (width * 3 / 2).rounded() }
    var captionHeight: CGFloat {
        #if os(tvOS)
        Metrics.posterCaptionHeight
        #else
        scaledCaptionHeight
        #endif
    }
    var captionLines: Int {
        #if os(tvOS)
        1
        #else
        dynamicTypeSize.isAccessibilitySize ? 2 : 1
        #endif
    }
    var spacing: CGFloat {
        #if os(tvOS)
        Metrics.Space.xl
        #else
        Metrics.Space.s
        #endif
    }
    var columns: [GridItem] {
        #if os(tvOS)
        Metrics.posterGridColumns
        #else
        [GridItem(.adaptive(minimum: width), spacing: Metrics.cardSpacing)]
        #endif
    }
    var imageWidth: Int { ArtworkSizing.pixels(for: width, displayScale: displayScale) }
    var imageSize: Int { ArtworkSizing.pixels(for: height, displayScale: displayScale) }
}

nonisolated enum ArtworkSizing {
    static func pixels(for points: CGFloat, displayScale: CGFloat) -> Int {
        guard points.isFinite, displayScale.isFinite else { return 1 }
        return Int(min(3840, max(1, (points * max(1, displayScale)).rounded(.up))))
    }
}

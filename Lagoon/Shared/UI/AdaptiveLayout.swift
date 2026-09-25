import SwiftUI
#if os(iOS)
import UIKit
#endif

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

/// Wraps metadata between tokens, and within a token wider than the view.
struct MetadataFlowLayout: Layout {
    var spacing: CGFloat = Metrics.Space.m
    /// Where each row sits in its unused width.
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        // A row is every frame sharing a minY.
        var rowWidths: [CGFloat: CGFloat] = [:]
        for frame in arrangement.frames {
            rowWidths[frame.minY] = max(rowWidths[frame.minY] ?? 0, frame.maxX)
        }
        for (index, frame) in arrangement.frames.enumerated() {
            let slack = max(0, bounds.width - (rowWidths[frame.minY] ?? 0))
            let shift: CGFloat = switch alignment {
            case .center: slack / 2
            case .trailing: slack
            default: 0
            }
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX + shift, y: bounds.minY + frame.minY),
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

extension EnvironmentValues {
    /// Set by a poster grid on its cards so they fill their column instead
    /// of keeping the rail width. Rails leave it nil.
    @Entry var posterCardWidth: CGFloat?
}

/// A grid resolved for a width. Paging thresholds scale with the column
/// count.
struct PosterGrid {
    let columns: [GridItem]
    let columnCount: Int
    /// nil until the grid has been measured, so cards keep their default.
    let cardWidth: CGFloat?
}

/// Cards and their grids must scale together with Dynamic Type.
struct PosterLayout: DynamicProperty {
    @ScaledMetric(relativeTo: .caption) private var scaledWidth = Metrics.posterWidth
    @ScaledMetric(relativeTo: .caption) private var scaledCaptionHeight = Metrics.posterCaptionHeight
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    @Environment(\.posterCardWidth) private var gridCardWidth

    var width: CGFloat {
        #if os(tvOS)
        Metrics.posterWidth
        #else
        gridCardWidth ?? min(scaledWidth, Metrics.accessibilityPosterWidth)
        #endif
    }

    /// iOS sizes cards to the column. The minimum is per idiom, not size
    /// class (a Pro Max is regular width in landscape), and scales with
    /// Dynamic Type. tvOS keeps five columns. Zero width means not measured.
    func grid(fitting availableWidth: CGFloat) -> PosterGrid {
        #if os(tvOS)
        return PosterGrid(columns: Metrics.posterGridColumns, columnCount: Metrics.gridColumns, cardWidth: nil)
        #else
        guard availableWidth > 0 else {
            return PosterGrid(columns: columns, columnCount: 2, cardWidth: nil)
        }
        let baseMinimum = UIDevice.current.userInterfaceIdiom == .pad
            ? Metrics.padGridPosterMinimum
            : Metrics.phoneGridPosterMinimum
        let spacing = Metrics.cardSpacing
        let count = PosterGridSizing.columnCount(
            availableWidth: availableWidth,
            baseMinimum: baseMinimum,
            scaledPosterWidth: scaledWidth,
            spacing: spacing
        )
        let cardWidth = ((availableWidth - spacing * CGFloat(count - 1)) / CGFloat(count)).rounded(.down)
        return PosterGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: count),
            columnCount: count,
            cardWidth: cardWidth
        )
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

#if os(iOS)
/// How many poster columns fit. Pure, so the Dynamic Type rule is testable.
enum PosterGridSizing {
    /// Larger text widens the cards; smaller text must not shrink them, or
    /// one step below the default squeezes a fourth column onto a phone.
    static func columnCount(
        availableWidth: CGFloat,
        baseMinimum: CGFloat,
        scaledPosterWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        let typeScale = max(scaledPosterWidth / Metrics.posterWidth, 1)
        let minimum = min(baseMinimum * typeScale, Metrics.accessibilityPosterWidth)
        return max(1, Int(((availableWidth + spacing) / (minimum + spacing)).rounded(.down)))
    }
}
#endif

nonisolated enum ArtworkSizing {
    static func pixels(for points: CGFloat, displayScale: CGFloat) -> Int {
        guard points.isFinite, displayScale.isFinite else { return 1 }
        return Int(min(3840, max(1, (points * max(1, displayScale)).rounded(.up))))
    }
}

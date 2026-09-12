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

/// Wrap metadata between tokens, but allow a token longer than the viewport
/// to wrap internally too. Unlike fixed-size HStacks, this also handles
/// translated strings and accessibility text sizes.
struct MetadataFlowLayout: Layout {
    var spacing: CGFloat = Metrics.Space.m
    /// Where each row sits in the width it did not use. Leading is the
    /// column composition; centre is the phone's block under the poster
    /// hero, where the title and actions are centred too (HEL-169).
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        // A row is every frame sharing a minY; its slack is what the
        // alignment distributes.
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
    /// of keeping the rail width (HEL-161). Rails leave it nil.
    @Entry var posterCardWidth: CGFloat?
}

/// What a grid resolved for the width it was given: the column set, how
/// many there are (paging thresholds scale with it), and the card width to
/// hand its cards through `posterCardWidth`.
struct PosterGrid {
    let columns: [GridItem]
    let columnCount: Int
    /// nil until the grid has been measured, so cards keep their default.
    let cardWidth: CGFloat?
}

/// Cards and their grids must scale together; scaling just the caption
/// leaves accessibility text crowded into a three-column phone grid.
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

    /// iOS grids size their cards to the column rather than the column to a
    /// rail-sized card: a portrait phone gets three across, an iPad four or
    /// more, and a wider window simply adds columns (HEL-161). The minimum
    /// is per idiom, not per size class: a Pro Max reports regular width in
    /// landscape, and a phone on its side wants six small posters, not four
    /// iPad-sized ones. The minimum scales with Dynamic Type the way the
    /// rail width does, so accessibility sizes still drop to fewer, larger
    /// cards. tvOS keeps its fixed five-column rhythm. A width of zero means
    /// "not measured yet".
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
        let typeScale = scaledWidth / Metrics.posterWidth
        let minimum = min(baseMinimum * typeScale, Metrics.accessibilityPosterWidth)
        let spacing = Metrics.cardSpacing
        let count = max(1, Int(((availableWidth + spacing) / (minimum + spacing)).rounded(.down)))
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

nonisolated enum ArtworkSizing {
    static func pixels(for points: CGFloat, displayScale: CGFloat) -> Int {
        guard points.isFinite, displayScale.isFinite else { return 1 }
        return Int(min(3840, max(1, (points * max(1, displayScale)).rounded(.up))))
    }
}

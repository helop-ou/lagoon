import SwiftUI

/// Where a partly folded iPhone Duo's fold runs down a view, in the view's
/// own leading-to-trailing coordinates.
nonisolated struct FoldCrossing: Equatable {
    var leadingEdge: CGFloat
    var trailingEdge: CGFloat
}

#if os(iOS)
/// The two sides of an active fold through a view, whichever way it runs.
nonisolated struct FoldSplit: Equatable {
    enum Side {
        case before
        case after
    }

    /// Above and below the fold, as in the laptop pose, not side by side.
    var isStacked: Bool
    /// Keeps content above or before the fold.
    var before: EdgeInsets
    /// Keeps content below or after it.
    var after: EdgeInsets

    func insets(_ side: Side) -> EdgeInsets {
        side == .before ? before : after
    }
}

/// Text and controls stay on one side of an active vertical fold. Content
/// that scrolls through a horizontal fold is left alone, as system lists do.
/// A view that does not scroll, such as the player, takes a side either way.
enum FoldLayout {
    /// Clear space kept between content and the fold.
    static let margin = Metrics.Space.l

    /// The first active vertical fold strictly inside a view of `width`.
    nonisolated static func crossing(folds: [CGRect], width: CGFloat) -> FoldCrossing? {
        folds
            .filter { $0.height > $0.width && $0.maxX > 0 && $0.minX < width }
            .min { $0.minX < $1.minX }
            .map { FoldCrossing(leadingEdge: max(0, $0.minX), trailingEdge: min(width, $0.maxX)) }
    }

    /// The first active fold strictly inside a view of `size`.
    nonisolated static func split(folds: [CGRect], size: CGSize) -> FoldSplit? {
        for fold in folds {
            if fold.height > fold.width {
                guard fold.minX > 0, fold.maxX < size.width else { continue }
                return FoldSplit(
                    isStacked: false,
                    before: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: size.width - fold.minX),
                    after: EdgeInsets(top: 0, leading: fold.maxX, bottom: 0, trailing: 0)
                )
            }
            guard fold.minY > 0, fold.maxY < size.height else { continue }
            return FoldSplit(
                isStacked: true,
                before: EdgeInsets(top: 0, leading: 0, bottom: size.height - fold.minY, trailing: 0),
                after: EdgeInsets(top: fold.maxY, leading: 0, bottom: 0, trailing: 0)
            )
        }
        return nil
    }

    nonisolated fileprivate static func activeFolds(in proxy: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
    }

    /// The widest leading-anchored content that starts `inset` in and still
    /// ends before the fold. Nil without a fold.
    static func leadingWidth(before crossing: FoldCrossing?, inset: CGFloat) -> CGFloat? {
        crossing.map { max(0, $0.leadingEdge - inset - margin) }
    }

    /// Columns split evenly into two halves, with the gap between the halves
    /// wide enough to cover the fold.
    static func gutter(width: CGFloat, crossing: FoldCrossing, spacing: CGFloat) -> CGFloat {
        let middle = width / 2
        let reach = max(middle - crossing.leadingEdge, crossing.trailingEdge - middle, 0)
        return max(spacing, 2 * (reach + margin))
    }
}

extension EnvironmentValues {
    /// Fold frames in a view's own coordinates, used in place of the
    /// measured ones. Snapshot tests set it, because no host can fold.
    @Entry var foldFramesOverride: [CGRect]?
}

extension View {
    /// Reports the active vertical fold crossing this view.
    func onFoldCrossingChange(_ action: @escaping (FoldCrossing?) -> Void) -> some View {
        modifier(FoldCrossingReader(action: action))
    }

    /// Reports the two sides of an active fold through this view.
    func onFoldSplitChange(_ action: @escaping (FoldSplit?) -> Void) -> some View {
        modifier(FoldSplitReader(action: action))
    }

    /// Fills its container, or one side of an active fold through it.
    func onFoldSide(_ side: FoldSplit.Side) -> some View {
        modifier(FoldSideLayout(side: side))
    }
}

private struct FoldCrossingReader: ViewModifier {
    @Environment(\.foldFramesOverride) private var override
    let action: (FoldCrossing?) -> Void

    func body(content: Content) -> some View {
        let override = override
        return content.onGeometryChange(for: FoldCrossing?.self) { proxy in
            FoldLayout.crossing(folds: override ?? FoldLayout.activeFolds(in: proxy), width: proxy.size.width)
        } action: { crossing in
            action(crossing)
        }
    }
}

private struct FoldSplitReader: ViewModifier {
    @Environment(\.foldFramesOverride) private var override
    let action: (FoldSplit?) -> Void

    func body(content: Content) -> some View {
        let override = override
        return content.onGeometryChange(for: FoldSplit?.self) { proxy in
            FoldLayout.split(folds: override ?? FoldLayout.activeFolds(in: proxy), size: proxy.size)
        } action: { split in
            action(split)
        }
    }
}

private struct FoldSideLayout: ViewModifier {
    let side: FoldSplit.Side
    @State private var split: FoldSplit?

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(split?.insets(side) ?? EdgeInsets())
            .onFoldSplitChange { split = $0 }
    }
}
#endif

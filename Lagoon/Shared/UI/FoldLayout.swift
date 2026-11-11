import SwiftUI

/// Where a partly folded iPhone Duo's fold runs down a view, in the view's
/// own leading-to-trailing coordinates.
nonisolated struct FoldCrossing: Equatable {
    var leadingEdge: CGFloat
    var trailingEdge: CGFloat
}

#if os(iOS)
/// Text and controls stay on one side of an active vertical fold. Content
/// that scrolls through a horizontal fold is left alone, as system lists do.
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
}

private struct FoldCrossingReader: ViewModifier {
    @Environment(\.foldFramesOverride) private var override
    let action: (FoldCrossing?) -> Void

    func body(content: Content) -> some View {
        let override = override
        return content.onGeometryChange(for: FoldCrossing?.self) { proxy in
            FoldLayout.crossing(folds: override ?? Self.activeFolds(in: proxy), width: proxy.size.width)
        } action: { crossing in
            action(crossing)
        }
    }

    nonisolated private static func activeFolds(in proxy: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .division).filter(\.isActive).map(\.frame)
    }
}
#endif

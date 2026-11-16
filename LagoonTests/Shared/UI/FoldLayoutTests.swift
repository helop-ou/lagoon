#if os(iOS)
import CoreGraphics
import SwiftUI
import Testing
@testable import Lagoon

/// A partly folded iPhone Duo keeps text and controls off its fold.
@Suite("Fold layout")
@MainActor
struct FoldLayoutTests {
    /// The open Duo's inner screen less the two screen gutters, with a 12-point
    /// fold down its middle.
    private let width: CGFloat = 669 - Metrics.screenGutter * 2
    private var centredFold: CGRect { CGRect(x: width / 2 - 6, y: 0, width: 12, height: 951) }

    @Test func onlyAVerticalFoldInsideTheViewCrossesIt() {
        #expect(FoldLayout.crossing(folds: [], width: width) == nil)
        // Laptop pose: the fold runs across, and scrolling content passes it.
        #expect(FoldLayout.crossing(folds: [CGRect(x: 0, y: 400, width: 951, height: 12)], width: width) == nil)
        // Beside the view, as for a view on one half.
        #expect(FoldLayout.crossing(folds: [CGRect(x: width + 10, y: 0, width: 12, height: 951)], width: width) == nil)
        #expect(
            FoldLayout.crossing(folds: [centredFold], width: width)
                == FoldCrossing(leadingEdge: centredFold.minX, trailingEdge: centredFold.maxX)
        )
    }

    @Test func leadingContentEndsAMarginBeforeTheFold() throws {
        #expect(FoldLayout.leadingWidth(before: nil, inset: 20) == nil)
        let crossing = try #require(FoldLayout.crossing(folds: [centredFold], width: width))
        #expect(FoldLayout.leadingWidth(before: crossing, inset: 20) == crossing.leadingEdge - 20 - FoldLayout.margin)
        // A fold before the inset leaves no room rather than a negative width.
        #expect(FoldLayout.leadingWidth(before: FoldCrossing(leadingEdge: 10, trailingEdge: 22), inset: 20) == 0)
    }

    /// The gap between equal halves sits on the middle, so it must reach a
    /// fold that is off the middle too.
    @Test(arguments: [CGFloat(0), 30, -30])
    func theGridGutterCoversTheFold(offset: CGFloat) throws {
        let fold = centredFold.offsetBy(dx: offset, dy: 0)
        let crossing = try #require(FoldLayout.crossing(folds: [fold], width: width))
        let split = PosterGridSizing.split(
            availableWidth: width,
            fold: crossing,
            baseMinimum: Metrics.padGridPosterMinimum,
            scaledPosterWidth: Metrics.posterWidth,
            spacing: Metrics.wideCardSpacing
        )
        let gutter = try #require(split.gutter)
        #expect(split.count.isMultiple(of: 2))
        #expect((width - gutter) / 2 <= crossing.leadingEdge - FoldLayout.margin)
        #expect((width + gutter) / 2 >= crossing.trailingEdge + FoldLayout.margin)
        // Every column fits inside its half.
        let half = CGFloat(split.count / 2)
        #expect(split.cardWidth * half + Metrics.wideCardSpacing * (half - 1) <= (width - gutter) / 2)
    }

    @Test func withoutAFoldTheGridIsUnchanged() {
        let split = PosterGridSizing.split(
            availableWidth: width,
            fold: nil,
            baseMinimum: Metrics.padGridPosterMinimum,
            scaledPosterWidth: Metrics.posterWidth,
            spacing: Metrics.wideCardSpacing
        )
        #expect(split.gutter == nil)
        #expect(split.count == PosterGridSizing.columnCount(
            availableWidth: width,
            baseMinimum: Metrics.padGridPosterMinimum,
            scaledPosterWidth: Metrics.posterWidth,
            spacing: Metrics.wideCardSpacing
        ))
    }

    /// The laptop pose, on the open Duo held tall.
    @Test func aFoldAcrossAViewSplitsItAboveAndBelow() throws {
        let split = try #require(FoldLayout.split(
            folds: [CGRect(x: 0, y: 470, width: 669, height: 12)],
            size: CGSize(width: 669, height: 951)
        ))
        #expect(split.isStacked)
        #expect(split.before == EdgeInsets(top: 0, leading: 0, bottom: 481, trailing: 0))
        #expect(split.after == EdgeInsets(top: 482, leading: 0, bottom: 0, trailing: 0))
        #expect(split.insets(.before) == split.before)
        #expect(split.insets(.after) == split.after)
    }

    /// The book pose, on the open Duo held wide.
    @Test func aFoldDownAViewSplitsItSideBySide() throws {
        let split = try #require(FoldLayout.split(
            folds: [CGRect(x: 470, y: 0, width: 12, height: 669)],
            size: CGSize(width: 951, height: 669)
        ))
        #expect(!split.isStacked)
        #expect(split.before == EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 481))
        #expect(split.after == EdgeInsets(top: 0, leading: 482, bottom: 0, trailing: 0))
    }

    @Test func onlyAFoldInsideAViewSplitsIt() {
        let size = CGSize(width: 669, height: 951)
        #expect(FoldLayout.split(folds: [], size: size) == nil)
        // At an edge or past it, as for a view on one half.
        #expect(FoldLayout.split(folds: [CGRect(x: 0, y: 0, width: 669, height: 12)], size: size) == nil)
        #expect(FoldLayout.split(folds: [CGRect(x: 0, y: 945, width: 669, height: 12)], size: size) == nil)
        #expect(FoldLayout.split(folds: [CGRect(x: 669, y: 0, width: 12, height: 951)], size: size) == nil)
    }
}
#endif

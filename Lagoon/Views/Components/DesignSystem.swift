import SwiftUI

// Layout and animation tokens — prefer these over literals.
// tvOS values follow the 80pt safe-zone gutter convention; iOS scales down.

enum Metrics {
    #if os(tvOS)
    static let screenGutter: CGFloat = 80
    static let cardSpacing: CGFloat = 40
    static let posterWidth: CGFloat = 260
    static let landscapeWidth: CGFloat = 360
    static let heroHeight: CGFloat = 620
    static let gridColumns = 5
    static let gridRowSpacing: CGFloat = 72
    /// Room under a poster for its title and year.
    static let posterCaptionHeight: CGFloat = 58
    static let railTopPadding: CGFloat = 40    // headroom for the system focus lift
    static let railBottomPadding: CGFloat = 80
    static let scrubberHeight: CGFloat = 8     // thin bar, per the Infuse reference
    /// Backdrop left uncovered above the info block — a scroll inset, not a
    /// spacer (see DetailPageScaffold). The reference starts its title about
    /// a third of the way down.
    static let detailHeroSpace: CGFloat = 210
    static let detailHeaderSpacing: CGFloat = 16
    static let detailSectionSpacing: CGFloat = 40
    static let detailBottomPadding: CGFloat = 80
    static let detailActionSpacing: CGFloat = 16
    static let castPortraitSize: CGFloat = 130
    static let castCaptionWidth: CGFloat = 180
    static let castCount = 8
    /// Box the title's logo artwork fits inside — height is what keeps a
    /// wide wordmark and a stacked one reading as the same design.
    static let logoMaxWidth: CGFloat = 620
    static let logoMaxHeight: CGFloat = 150
    /// Shorter than a detail page's: the hero pairs it with a synopsis.
    static let heroLogoHeight: CGFloat = 110
    /// The hero's text column. Bounded on tvOS so it doesn't run under the
    /// artwork; on a phone there is no room to bound it, so it takes what it
    /// is given.
    static let heroTextWidth: CGFloat = 640
    static let heroTextInset: CGFloat = 56
    /// Square avatar tile in the account picker (HEL-38).
    static let accountTileSize: CGFloat = 220
    /// Section list in the split Settings layout — wide enough for the
    /// longest label plus its focus lozenge, narrow enough that the content
    /// pane still owns the screen.
    static let settingsSidebarWidth: CGFloat = 340
    #else
    static let screenGutter: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    static let posterWidth: CGFloat = 105
    static let landscapeWidth: CGFloat = 240
    static let heroHeight: CGFloat = 380
    static let gridColumns = 3
    static let gridRowSpacing: CGFloat = 28
    static let posterCaptionHeight: CGFloat = 38
    static let railTopPadding: CGFloat = 6
    static let railBottomPadding: CGFloat = 10
    static let accountTileSize: CGFloat = 110
    static let scrubberHeight: CGFloat = 8     // matches the AVKit transport bar
    static let detailHeroSpace: CGFloat = 100
    static let detailHeaderSpacing: CGFloat = 12
    static let detailSectionSpacing: CGFloat = 32
    /// The liquid tab bar floats over scroll content. The final rail needs
    /// enough runway to clear it rather than finishing underneath it.
    static let detailBottomPadding: CGFloat = 110
    /// Glass circles carry their own generous touch frame on iOS; additional
    /// HStack spacing makes the visible controls look disconnected.
    static let detailActionSpacing: CGFloat = 0
    static let castPortraitSize: CGFloat = 72
    static let castCaptionWidth: CGFloat = 104
    // No castCount on iOS: the strip scrolls there, so it shows everyone.
    static let logoMaxWidth: CGFloat = 240
    static let logoMaxHeight: CGFloat = 70
    static let heroLogoHeight: CGFloat = 54
    static let heroTextWidth: CGFloat = .infinity
    static let heroTextInset: CGFloat = 20
    #endif

    /// The spacing scale (HEL-51). Every gap and inset *inside* a screen
    /// picks a step from here; the structural values above (gutter, card
    /// sizes, hero height) stay separate because they answer to the 10-foot
    /// safe zone rather than to rhythm.
    ///
    /// Roughly ×1.5 after `s`, which is what makes adjacent steps read as
    /// different rather than as a mistake. The same values on both platforms
    /// for now: internal rhythm doesn't need to shrink the way structure
    /// does, and giving iOS its own scale is HEL-41's call, not a change to
    /// make blind.
    ///
    /// | step | pt | for |
    /// |---|---|---|
    /// | `hair` | 2 | a label sitting on its value |
    /// | `xs` | 4 | inside a control |
    /// | `s` | 8 | between tight siblings |
    /// | `m` | 12 | the default gap |
    /// | `l` | 16 | between groups |
    /// | `xl` | 24 | card padding, form rows |
    /// | `xxl` | 40 | between sections |
    /// | `section` | 56 | between major blocks |
    enum Space {
        static let hair: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 40
        static let section: CGFloat = 56
    }

    /// Columns for a poster grid. tvOS has exactly one screen size, so a
    /// fixed count is the right call there and keeps the approved 5-column
    /// rhythm. iOS spans SE to Pro Max, where a fixed count is what made
    /// cards wider than their columns and cut the first and last off the
    /// screen (HEL-41) — so the count follows the width instead.
    static var posterGridColumns: [GridItem] {
        #if os(tvOS)
        Array(repeating: GridItem(.flexible(), spacing: cardSpacing), count: gridColumns)
        #else
        [GridItem(.adaptive(minimum: posterWidth), spacing: cardSpacing)]
        #endif
    }

    static var posterHeight: CGFloat { (posterWidth * 3 / 2).rounded() }
    static var landscapeHeight: CGFloat { (landscapeWidth * 9 / 16).rounded() }

    static let cardCornerRadius: CGFloat = 12
    static let cardArtRadius: CGFloat = 10
    static let badgeCornerRadius: CGFloat = 6
    static let panelCornerRadius: CGFloat = 32
    static let progressBarHeight: CGFloat = 6
}

/// The only sanctioned escapes from the Dynamic Type scale (HEL-51).
///
/// Everything that is *text* uses a semantic style — `.callout`, `.headline`,
/// `.caption` — so it scales and stays consistent. Two things legitimately
/// don't: SF Symbols used as artwork (an empty state's glyph is a picture,
/// not a sentence) and display type that is effectively a logo. Naming them
/// here keeps `.system(size:)` out of the screens, where each new call site
/// would otherwise invent its own size.
enum Typography {
    /// Big SF Symbol standing in for artwork — empty and error states.
    static let glyph: Font = .system(size: 48)
    /// The same idea where it carries a whole screen.
    static let largeGlyph: Font = .system(size: 56)
    /// The Lagoon wordmark on the connect screen.
    static let wordmark: Font = .system(size: 52, weight: .bold)
    /// Quick Connect's code: monospaced so the digits don't jitter as it
    /// polls, and large enough to read across a room.
    static let quickConnectCode: Font = .system(size: 42, weight: .bold, design: .monospaced)
}

enum Motion {
    static let fast: TimeInterval = 0.2       // focus platters, small reveals
    static let standard: TimeInterval = 0.4   // layer swaps, state transitions
    static let slow: TimeInterval = 0.6       // hero slide change
    static let crossfade: TimeInterval = 0.8  // backdrop / ambient-glow crossfade
}

// Brand colors are only for genuine branding: progress fills, the wordmark,
// selection markers. Everything else uses system semantic styles.
extension Color {
    static let lagoonTeal = Color(red: 74 / 255, green: 209 / 255, blue: 199 / 255)
    static let lagoonDeep = Color(red: 8 / 255, green: 46 / 255, blue: 68 / 255)
}

extension View {
    /// System card style on tvOS (lift, parallax, specular); plain elsewhere.
    @ViewBuilder
    func cardButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
}

/// Brand wash for the onboarding screens only.
struct BrandBackgroundGradient: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: Color.lagoonDeep.opacity(0.9), location: 0),
                .init(color: Color.lagoonDeep.opacity(0.55), location: 0.4),
                .init(color: Color.lagoonDeep.opacity(0.2), location: 0.8),
                .init(color: .clear, location: 1),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .background(Color.black)
        .ignoresSafeArea()
    }
}

import SwiftUI

// Layout and animation tokens — prefer these over literals.
// tvOS values follow the 80pt safe-zone gutter convention; iOS scales down.

enum Metrics {
    #if os(tvOS)
    static let screenGutter: CGFloat = 80
    static let cardSpacing: CGFloat = 40
    static let posterWidth: CGFloat = 280
    static let landscapeWidth: CGFloat = 360
    static let heroHeight: CGFloat = 620
    static let gridColumns = 5
    static let gridRowSpacing: CGFloat = 72
    /// Room under a poster for its title and year.
    static let posterCaptionHeight: CGFloat = 58
    /// Room under a landscape card for a name and a count. Taller than a
    /// poster's because the names that need it are collections, and
    /// "Spider-Man (MCU) Collection" does not fit on one line (HEL-122).
    static let landscapeCaptionHeight: CGFloat = 96
    static let railTopPadding: CGFloat = 48    // headroom for the system focus lift and the focus halo
    static let railBottomPadding: CGFloat = 96
    static let scrubberHeight: CGFloat = 6     // flat native transport rail
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
    /// The brand symbol's height in the onboarding lockup. Sized to read as
    /// a mark across a room without competing with the screen's heading.
    static let lockupSymbolHeight: CGFloat = 150
    /// A smaller lockup for a screen that already has a title of its own.
    static let lockupHeaderSymbolHeight: CGFloat = 64
    static let jellyfishAccentHeight: CGFloat = 88
    /// Identity column in Settings — avatar, user, server. Sized so the
    /// settings list beside it still gets the larger half.
    static let settingsIdentityWidth: CGFloat = 460
    static let settingsAvatarSize: CGFloat = 260
    #else
    static let screenGutter: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    /// Two comfortable columns on a typical portrait phone, shared with
    /// poster rails so recommendations aren't reduced to thumbnails.
    static let posterWidth: CGFloat = 160
    static let accessibilityPosterWidth: CGFloat = 240
    static let landscapeWidth: CGFloat = 240
    /// A landscape banner at standard text sizes; HeroSection grows for
    /// Dynamic Type when its title and synopsis need more room.
    static let heroHeight: CGFloat = 200
    /// More artwork above the copy in regular-width iPad windows.
    static let expandedHeroHeight: CGFloat = 360
    static let gridColumns = 2
    static let gridRowSpacing: CGFloat = Space.xxl
    static let posterCaptionHeight: CGFloat = 38
    static let landscapeCaptionHeight: CGFloat = 60
    /// Keep a heading close to its own cards, with a larger break before
    /// the next shelf. Browse pages stack rails without extra spacing.
    static let railTopPadding: CGFloat = Space.m
    static let railBottomPadding: CGFloat = Space.xxl
    static let accountTileSize: CGFloat = 110
    static let scrubberHeight: CGFloat = 6     // flat native transport rail
    static let detailHeroSpace: CGFloat = 100
    static let detailHeaderSpacing: CGFloat = 12
    static let detailSectionSpacing: CGFloat = 32
    /// The liquid tab bar floats over scroll content. The final rail needs
    /// enough runway to clear it rather than finishing underneath it.
    static let detailBottomPadding: CGFloat = 110
    /// Keep the native large glass actions distinct and easy to tap.
    static let detailActionSpacing: CGFloat = Space.s
    static let castPortraitSize: CGFloat = 72
    static let castCaptionWidth: CGFloat = 104
    // No castCount on iOS: the strip scrolls there, so it shows everyone.
    static let logoMaxWidth: CGFloat = 240
    static let logoMaxHeight: CGFloat = 70
    static let heroLogoHeight: CGFloat = 54
    static let heroTextWidth: CGFloat = .infinity
    /// Keep iPad hero copy readable without spanning the whole banner.
    static let expandedHeroTextWidth: CGFloat = 520
    static let heroTextInset: CGFloat = 20
    static let lockupSymbolHeight: CGFloat = 78
    static let lockupHeaderSymbolHeight: CGFloat = 34
    static let jellyfishAccentHeight: CGFloat = 38
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

    /// A sheet with custom content ignores `presentationSizing` on tvOS, so
    /// a modal panel states its own size or it fills the screen.
    #if os(tvOS)
    static let modalPanelSize = CGSize(width: 1_240, height: 760)
    #else
    static let modalPanelSize = CGSize(width: 420, height: 560)
    #endif

    static var posterHeight: CGFloat { (posterWidth * 3 / 2).rounded() }
    static var landscapeHeight: CGFloat { (landscapeWidth * 9 / 16).rounded() }

    static let cardCornerRadius: CGFloat = 12
    static let cardArtRadius: CGFloat = 10
    /// The focused card's artwork-derived halo. Blurred far enough that no
    /// edge of the gradient reads as a shape, and kept well under full
    /// strength so it kindles the space around the card rather than
    /// competing with the artwork inside it.
    static let focusHaloBlur: CGFloat = 36
    static let focusHaloOpacity: Double = 0.55
    static let badgeCornerRadius: CGFloat = 6
    static let panelCornerRadius: CGFloat = 32
    /// iOS hero clipping; tvOS heroes use the native card shape.
    static let heroCornerRadius: CGFloat = 16
    static let progressBarHeight: CGFloat = 6
    static let touchTarget: CGFloat = 44
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

// Brand colors are only for genuine branding: progress fills, the lockup,
// selection markers. Everything else uses system semantic styles.
//
// These are the Twin Shores palette from the brand package, and the names
// deliberately do **not** follow it. The package calls #0D4A57 "Lagoon Teal",
// which is the dark upper shore — while this codebase has always used
// `lagoonTeal` for the bright accent. Keeping that name would leave one word
// meaning two colors, so the roles are named after the mark instead: aqua is
// the lower shore, shore the upper one, navy the ground they sit on.
extension Color {
    /// Aqua — the lower shore, and the only brand color bright enough to
    /// carry an accent against black.
    nonisolated static let lagoonAqua = Color(red: 0x2E / 255, green: 0xD4 / 255, blue: 0xC7 / 255)
    /// Deep Navy — the brand's ground. Lagoon keeps true black behind its
    /// content, so this is a wash over black rather than a background.
    nonisolated static let lagoonNavy = Color(red: 0x0B / 255, green: 0x1D / 255, blue: 0x28 / 255)
    /// Lagoon Teal in the brand package — the mark's upper shore.
    nonisolated static let lagoonShore = Color(red: 0x0D / 255, green: 0x4A / 255, blue: 0x57 / 255)
}

/// SF Symbols, in one place for the kinds of thing the app navigates to, so a
/// library tab, the library picker and Discover's catalogue buttons cannot
/// drift apart — which is exactly what had happened.
///
/// **Fill is not a free choice.** Three families, each internally consistent:
///
/// - **Navigation** (tabs, library rows) is *filled*. That is the platform
///   convention for a tab bar and it is what survives being read across a
///   room.
/// - **Transport** (`play.fill`, `pause.fill`, `forward.end.alt.fill`) is
///   *filled*, matching every other player on the platform.
/// - **Empty and error states** (`exclamationmark.triangle`, `play.slash`,
///   `tray`, `wifi.exclamationmark`) are *outline*. They are artwork rather
///   than controls, and outline keeps them from shouting.
///
/// A literal "everything filled" is not achievable and should not be
/// attempted: `checkmark`, `chevron.*`, `plus`, `minus`, `xmark`,
/// `magnifyingglass` and `speedometer` are strokes by construction and have no
/// filled variant.
/// Glyphs are also chosen for *shape*, not only meaning. Measured at a common
/// point size, `house.fill` and `gearshape.fill` are the fixed anchors of the
/// tab bar at 1.13 and 1.00 width-to-height and ~0.55 ink density, and every
/// other tab has to sit near them or it reads as out of place. The set below
/// spans 1.00–1.13 and 0.28–0.81.
///
/// What that replaced: `film.fill` was 1.28 wide and 0.85 dense — both the
/// widest *and* the heaviest glyph in the bar, which is why Movies looked
/// wrong; and `play.square.stack.fill` was 0.75, the outlier at the opposite
/// end, so the two sat beside each other mismatched in both directions.
nonisolated enum ContentIcon {
    /// A clapperboard. 1.04 — square enough to sit beside the gear, where a
    /// film strip's 1.28 could not.
    static let movies = "movieclapper.fill"
    /// A stack with a play badge: a series is a pile of episodes rather than
    /// one item, which is also what tells it apart from Movies at a glance.
    /// 1.10, near-identical to the house beside it.
    static let shows = "rectangle.stack.badge.play.fill"
    /// Every library at once, when there are too many for tabs of their own.
    /// A grid rather than a stack, so it cannot be mistaken for Shows.
    static let libraries = "square.grid.2x2.fill"
    static let home = "house.fill"
    /// The single sparkle, not the cluster: `sparkles` measured 0.81, narrow
    /// and lopsided next to the rest. It stays the lightest glyph in the bar
    /// at 0.28 ink, which is what a sparkle is — forcing it heavier would make
    /// it something else.
    static let discover = "sparkle"
    /// A stroke by construction, like `sparkle` beside it: SF Symbols has no
    /// filled magnifier, and the circled variants read as a button rather
    /// than a tab. `Tab(role: .search)` may substitute the system's own
    /// glyph here, which is the outcome we want either way.
    static let search = "magnifyingglass"
    static let settings = "gearshape.fill"

    /// Settings destinations share the same filled navigation vocabulary.
    nonisolated enum Settings {
        static let account = "person.crop.circle.fill"
        static let playback = "play.circle.fill"
        static let audio = "speaker.wave.2.fill"
        static let subtitles = "captions.bubble.fill"
        static let advanced = "wrench.and.screwdriver.fill"
        static let developer = "hammer.fill"
        static let about = "info.circle.fill"
    }

    /// Jellyfin's collection type for a library, as a glyph.
    static func library(collectionType: String?) -> String {
        collectionType == "tvshows" ? shows : movies
    }
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

/// The brand surface the onboarding screens sit on.
///
/// The guidelines call Deep Navy "the default full-bleed field", and onboarding
/// takes them at their word: it is the app's front door and the stretch that is
/// purely identity, so the mark gets a field behind it rather than a void. Past
/// it, black is the ground Lagoon plays content against, and `MainTabView`
/// onwards is unchanged.
///
/// Deep Navy is RGB(11, 29, 40), so this is not far from black to begin with.
struct BrandBackground: View {
    var body: some View {
        Color.lagoonNavy.ignoresSafeArea()
    }
}

/// The Twin Shores lockup: the two-tone symbol beside or above the wordmark.
///
/// Composed here rather than shipped as one asset because the brand package
/// has no dark-background lockup. Its color lockup sets the wordmark in Ink
/// (#07161D), which is invisible on black, and its white lockup flattens the
/// two shores into a single silhouette — losing the one idea the mark is
/// carrying. Pairing the color symbol with the Light wordmark keeps both.
///
/// The proportions are not invented. They are measured off the package's own
/// `Lagoon_Lockup_Stacked_Color` and `_Horizontal_Color`, which do not agree
/// with each other — the horizontal lockup sets the wordmark nearly twice as
/// large relative to the mark, because beside it rather than beneath it the
/// word has to hold its own. `import-brand-vectors.swift` crops both assets to
/// their ink, so these ratios apply to the frames directly.
struct LagoonLockup: View {
    enum Layout {
        /// Symbol above wordmark, for a screen that is mostly lockup.
        case stacked
        /// Symbol beside wordmark, for a header.
        case horizontal

        /// Wordmark height as a fraction of the symbol's.
        var wordmarkRatio: CGFloat {
            switch self {
            case .stacked: 0.264
            case .horizontal: 0.481
            }
        }

        /// Gap between the two, likewise relative to the symbol.
        var gapRatio: CGFloat {
            switch self {
            case .stacked: 0.174
            case .horizontal: 0.195
            }
        }
    }

    var layout: Layout = .stacked
    /// Height of the symbol. Everything else is derived from it, so a call
    /// site sizes the lockup with one number.
    var symbolHeight: CGFloat = Metrics.lockupSymbolHeight

    private var wordmarkHeight: CGFloat { symbolHeight * layout.wordmarkRatio }
    private var gap: CGFloat { symbolHeight * layout.gapRatio }
    /// "Keep lockup clear space equal to half the symbol height on all
    /// sides" — the guidelines' rule, enforced by the component rather than
    /// left to each call site, where it was already being broken four times
    /// out of four.
    private var clearSpace: CGFloat { symbolHeight / 2 }

    var body: some View {
        Group {
            switch layout {
            case .stacked:
                VStack(spacing: gap) {
                    symbol
                    wordmark
                }
            case .horizontal:
                HStack(spacing: gap) {
                    symbol
                    // The package centres the wordmark's *cap height* on the
                    // symbol, not its ink box. Centring the box instead would
                    // hang the whole word low by the depth of the g's
                    // descender, which is what makes an assembled lockup look
                    // assembled.
                    wordmark.offset(y: -symbolHeight * 0.053)
                }
            }
        }
        .padding(clearSpace)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Lagoon")
    }

    private var symbol: some View {
        Image("LagoonSymbol")
            .resizable()
            .scaledToFit()
            .frame(height: symbolHeight)
    }

    private var wordmark: some View {
        Image("LagoonWordmark")
            .resizable()
            .scaledToFit()
            .frame(height: wordmarkHeight)
    }
}

/// The secondary jellyfish, used the way the brand package restricts it:
/// "only as punctuation in loading, empty-state, or atmospheric moments …
/// small, one-color, and low contrast." It is a template image, so the tint
/// comes from the call site rather than from the artwork.
struct LagoonJellyfishAccent: View {
    var height: CGFloat = Metrics.jellyfishAccentHeight

    var body: some View {
        Image("LagoonJellyfish")
            .renderable(template: true)
            .scaledToFit()
            .frame(height: height)
            .foregroundStyle(Color.lagoonAqua.opacity(0.35))
            .accessibilityHidden(true)
    }
}

private extension Image {
    /// `.resizable()` plus the template intent in one place, so the accent's
    /// one-color rule is not restated at every call site.
    func renderable(template: Bool) -> some View {
        renderingMode(template ? .template : .original).resizable()
    }
}

import SwiftUI

// Layout and animation tokens. Use these, never literals.
// tvOS values follow the 80pt safe-zone gutter; iOS scales down.

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
    /// poster's because long collection names wrap to two lines.
    static let landscapeCaptionHeight: CGFloat = 96
    /// Width reserved for the oversized rank beside a Top 10 card.
    static let topTenRankWidth: CGFloat = 150
    /// Pulls the card over the rank so the number reads as part of the card.
    static let topTenRankOverlap: CGFloat = 28
    static let railTopPadding: CGFloat = 48    // headroom for the system focus lift and the focus halo
    static let railBottomPadding: CGFloat = 96
    static let scrubberHeight: CGFloat = 6     // flat native transport rail
    /// Backdrop left uncovered above the info block. A scroll inset, not a
    /// spacer (see DetailPageScaffold).
    static let detailHeroSpace: CGFloat = 210
    static let detailHeaderSpacing: CGFloat = 16
    static let detailSectionSpacing: CGFloat = 40
    static let detailBottomPadding: CGFloat = 80
    static let detailActionSpacing: CGFloat = 16
    static let castPortraitSize: CGFloat = 130
    static let castCaptionWidth: CGFloat = 180
    static let castCount = 8
    /// Box the title's logo fits inside. The height cap keeps wide and
    /// stacked logos looking the same size.
    static let logoMaxWidth: CGFloat = 620
    static let logoMaxHeight: CGFloat = 150
    /// Shorter than a detail page's: the hero pairs it with a synopsis.
    static let heroLogoHeight: CGFloat = 110
    /// The hero's text column, bounded so it doesn't run under the artwork.
    static let heroTextWidth: CGFloat = 640
    static let heroTextInset: CGFloat = 56
    /// A profile's round portrait in the "Who's watching?" picker: one row
    /// when every profile is on one server, and smaller when rows are
    /// grouped by server, so three servers fit one screen.
    static let profilePortraitSize: CGFloat = 200
    static let groupedProfilePortraitSize: CGFloat = 130
    static let lockupSymbolHeight: CGFloat = 150
    /// A smaller lockup for a screen that already has a title of its own.
    static let lockupHeaderSymbolHeight: CGFloat = 64
    static let jellyfishAccentHeight: CGFloat = 88
    /// Identity column in Settings. The list beside it keeps the larger half.
    static let settingsIdentityWidth: CGFloat = 460
    static let settingsAvatarSize: CGFloat = 260
    #else
    static let screenGutter: CGFloat = 20
    static let cardSpacing: CGFloat = 14
    /// The rail card. Grids size cards to the column (`PosterLayout.grid`).
    static let posterWidth: CGFloat = 160
    static let accessibilityPosterWidth: CGFloat = 240
    /// Smallest grid card before a column is dropped: three across on a
    /// portrait SE, six on its side, four or more on an iPad.
    static let phoneGridPosterMinimum: CGFloat = 100
    static let padGridPosterMinimum: CGFloat = 150
    static let landscapeWidth: CGFloat = 240
    /// At standard text sizes; HeroSection grows it for Dynamic Type.
    static let heroHeight: CGFloat = 200
    static let expandedHeroHeight: CGFloat = 360
    static let gridRowSpacing: CGFloat = Space.xxl
    static let posterCaptionHeight: CGFloat = 38
    static let landscapeCaptionHeight: CGFloat = 60
    static let topTenRankWidth: CGFloat = 88
    static let topTenRankOverlap: CGFloat = 16
    /// A heading sits close to its cards, with a larger break before the
    /// next shelf.
    static let railTopPadding: CGFloat = Space.m
    static let railBottomPadding: CGFloat = Space.xxl
    /// A profile's round portrait in the "Who's watching?" picker.
    static let profilePortraitSize: CGFloat = 84
    static let groupedProfilePortraitSize: CGFloat = 84
    static let touchAvatarSize: CGFloat = 64
    static let scrubberHeight: CGFloat = 6     // flat native transport rail
    static let detailHeroSpace: CGFloat = 100
    static let expandedDetailHeroSpace: CGFloat = 240
    /// Cap on the poster hero as a share of the safe-area height, so the
    /// title is never pushed off-screen. On a phone the hero shows the
    /// poster's upper part.
    static let detailPosterHeroMaxShare: CGFloat = 0.72
    /// Landscape artwork as a portrait hero: this share of the window
    /// height, filled and centred, with the sides cropped.
    static let detailBackdropHeroShare: CGFloat = 0.6
    /// How far the metadata block overlaps the poster hero, as a share of
    /// its height. The fade beneath it is drawn to match.
    static let detailPosterContentOverlap: CGFloat = 0.36
    /// On a landscape phone, the title/actions/Play row starts at this share
    /// of the window height, leaving the facts and synopsis below the fold.
    static let detailLandscapeRowShare: CGFloat = 0.88
    /// Blur of the poster copy that fills the sides of a landscape hero.
    static let detailPosterAmbientBlur: CGFloat = 36
    /// Caps the phone's Play pill so it never becomes a bar across the
    /// screen. The landscape row shares its width, so its cap is smaller.
    static let detailPlayButtonMaxWidth: CGFloat = 360
    static let detailLandscapePlayButtonMaxWidth: CGFloat = 260
    static let detailHeaderSpacing: CGFloat = 12
    static let detailSectionSpacing: CGFloat = 32
    /// Runway for the last rail to clear the floating tab bar.
    static let detailBottomPadding: CGFloat = 110
    static let detailActionSpacing: CGFloat = Space.s
    static let castPortraitSize: CGFloat = 72
    static let castCaptionWidth: CGFloat = 104
    // No castCount on iOS: the strip scrolls there, so it shows everyone.
    static let logoMaxWidth: CGFloat = 240
    static let logoMaxHeight: CGFloat = 70
    static let heroLogoHeight: CGFloat = 54
    static let heroTextWidth: CGFloat = .infinity
    static let expandedHeroTextWidth: CGFloat = 520
    /// The detail header's info column in a regular-width iPad window,
    /// laid out beside the artwork as on the TV.
    static let expandedDetailColumnWidth: CGFloat = 640
    static let heroTextInset: CGFloat = 20
    static let lockupSymbolHeight: CGFloat = 78
    static let lockupHeaderSymbolHeight: CGFloat = 34
    static let jellyfishAccentHeight: CGFloat = 38
    static let downloadRingLineWidth: CGFloat = 2.5
    /// The download progress ring and the poster's "downloaded" badge glyph.
    static let downloadMarkSize: CGFloat = 18
    #endif

    /// The touch detail page's poster hero, in pixels. The decode budget is
    /// the 2:3 image's longest edge, because `maxPixelSize` caps the longest
    /// edge; a width-sized budget would decode soft. Declared on both
    /// platforms because the URL is built unconditionally.
    static let detailPosterRequestWidth = 1200
    static let detailPosterDecodeSize = 1800
    /// Decoded at the request width, so a full-width landscape hero is not
    /// decoded small and upscaled soft.
    static let detailBackdropRequestWidth = 1920
    static let detailBackdropDecodeSize = 1920
    /// The large control height, so the circles sit level with the Play pill.
    static let detailCircleActionSize: CGFloat = 50
    /// Small decode: the blurred ambient copy needs no detail.
    static let detailPosterAmbientDecodeSize = 240

    /// The spacing scale for gaps and insets *inside* a screen. Structural
    /// values above follow the safe zone, not this scale. Roughly ×1.5 per
    /// step after `s`, so adjacent steps look deliberately different.
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

    /// Columns for a poster grid: fixed on tvOS (one screen size), adaptive
    /// on iOS, where a fixed count cut the outer cards off small screens.
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

    static var landscapeHeight: CGFloat { (landscapeWidth * 9 / 16).rounded() }

    static let cardCornerRadius: CGFloat = 12
    static let cardArtRadius: CGFloat = 10
    /// The focused card's artwork halo: blurred so no edge reads as a shape,
    /// and faint so it doesn't compete with the artwork.
    static let focusHaloBlur: CGFloat = 36
    static let focusHaloOpacity: Double = 0.55
    static let badgeCornerRadius: CGFloat = 6
    static let panelCornerRadius: CGFloat = 32

    /// The QR code's side, and a floor under its white margin.
    ///
    /// A code scans from about ten times its width, so the TV needs a large
    /// one to scan from a sofa. iOS opens the link instead; its size exists
    /// only for the component gallery.
    ///
    /// The real quiet zone is four modules, measured from the generated code
    /// by `QRCode.quietZone(side:modulesAcross:)`. This is the floor before
    /// a code exists.
    #if os(tvOS)
    static let qrCodeSize: CGFloat = 420
    static let qrCodeMinimumQuietZone: CGFloat = 32
    #else
    static let qrCodeSize: CGFloat = 220
    static let qrCodeMinimumQuietZone: CGFloat = 16
    #endif
    /// iOS hero clipping; tvOS heroes use the native card shape.
    static let heroCornerRadius: CGFloat = 16
    static let progressBarHeight: CGFloat = 6
    static let themeSwatchSize: CGFloat = 28
    /// A card's small round badges, "downloaded" and "watched". On iOS this
    /// matches `downloadMarkSize` so the badge and the ring match.
    #if os(tvOS)
    static let cardMarkSize: CGFloat = 28
    static let cardMarkInset: CGFloat = Space.s
    #else
    static let cardMarkSize: CGFloat = 18
    static let cardMarkInset: CGFloat = Space.xs
    #endif
    static let touchTarget: CGFloat = 44
}

/// The only allowed escapes from the Dynamic Type scale: symbols used as
/// artwork and display type that acts as a logo. All other text uses a
/// semantic style. Keep `.system(size:)` out of the screens.
enum Typography {
    /// Big SF Symbol standing in for artwork — empty and error states.
    static let glyph: Font = .system(size: 48)
    static let largeGlyph: Font = .system(size: 56)
    /// Monospaced so the digits don't jitter as the code polls.
    static let quickConnectCode: Font = .system(size: 42, weight: .bold, design: .monospaced)
    /// Oversized display number used by the ranked Home shelves.
    #if os(tvOS)
    static let topTenRank: Font = .system(size: 190, weight: .black, design: .rounded)
    #else
    static let topTenRank: Font = .system(size: 112, weight: .black, design: .rounded)
    #endif
}

enum Motion {
    static let fast: TimeInterval = 0.2       // focus platters, small reveals
    static let standard: TimeInterval = 0.4   // layer swaps, state transitions
    static let slow: TimeInterval = 0.6       // hero slide change
    static let crossfade: TimeInterval = 0.8  // backdrop / ambient-glow crossfade
}

// Brand colors are only for branding: progress fills, the lockup, selection
// markers. Everything else uses system semantic styles.
//
// The Twin Shores palette, deliberately renamed: the brand package's
// "Lagoon Teal" is `lagoonShore` here, to avoid one word meaning two colors.
extension Color {
    /// The only brand color bright enough for an accent on black.
    nonisolated static let lagoonAqua = Color(red: 0x2E / 255, green: 0xD4 / 255, blue: 0xC7 / 255)
    /// Deep Navy. A wash over black, not a content background.
    nonisolated static let lagoonNavy = Color(red: 0x0B / 255, green: 0x1D / 255, blue: 0x28 / 255)
    /// Lagoon Teal in the brand package — the mark's upper shore.
    nonisolated static let lagoonShore = Color(red: 0x0D / 255, green: 0x4A / 255, blue: 0x57 / 255)
    /// Ink, for dark-on-light.
    nonisolated static let lagoonInk = Color(red: 0x07 / 255, green: 0x16 / 255, blue: 0x1D / 255)
    /// Mist, the light ground Ink sits on.
    nonisolated static let lagoonMist = Color(red: 0xE9 / 255, green: 0xF1 / 255, blue: 0xF2 / 255)
}

/// SF Symbols for navigation targets, in one place so tabs, pickers and
/// Discover's buttons cannot drift apart.
///
/// Navigation and transport are filled; empty and error states are outline.
/// `checkmark`, `chevron.*`, `plus`, `minus`, `xmark`, `magnifyingglass` and
/// `speedometer` have no filled variant.
///
/// Tab glyphs are also matched for shape: width-to-height 1.00–1.13, like
/// `house.fill` and `gearshape.fill`. `film.fill` (1.28) looked wrong.
nonisolated enum ContentIcon {
    static let movies = "movieclapper.fill"
    static let shows = "rectangle.stack.badge.play.fill"
    /// All libraries, when there are too many for tabs. A grid, so it is not
    /// mistaken for Shows.
    static let libraries = "square.grid.2x2.fill"
    static let home = "house.fill"
    /// The single sparkle: `sparkles` (0.81) is narrow and lopsided.
    static let discover = "sparkle"
    /// No filled magnifier exists; circled variants read as a button.
    /// `Tab(role: .search)` may substitute the system glyph, which is fine.
    static let search = "magnifyingglass"
    static let settings = "gearshape.fill"

    nonisolated enum Settings {
        static let account = "person.crop.circle.fill"
        static let playback = "play.circle.fill"
        static let audio = "speaker.wave.2.fill"
        static let subtitles = "captions.bubble.fill"
        static let advanced = "wrench.and.screwdriver.fill"
        static let developer = "hammer.fill"
        static let about = "info.circle.fill"
        static let downloads = "arrow.down.circle.fill"
        static let appearance = "paintpalette.fill"
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

/// The onboarding screens' background: the theme's `ground` (Deep Navy under
/// Lagoon). Past onboarding, content sits on the theme's background.
/// `ThemeStore` picks the theme: the last profile's until another signs in.
struct GroundBackground: View {
    var body: some View {
        Theme.ground.ignoresSafeArea()
    }
}

/// The Twin Shores lockup: the two-tone symbol beside or above the wordmark.
///
/// Composed here because the brand package has no dark-background lockup.
/// Ratios are measured from `Lagoon_Lockup_Stacked_Color` and
/// `_Horizontal_Color`; `import-brand-vectors.swift` crops both to their ink,
/// so they apply to the frames directly.
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
    /// Everything else derives from this.
    var symbolHeight: CGFloat = Metrics.lockupSymbolHeight

    private var wordmarkHeight: CGFloat { symbolHeight * layout.wordmarkRatio }
    private var gap: CGFloat { symbolHeight * layout.gapRatio }
    /// Brand rule: clear space of half the symbol height on all sides.
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
                    // Centre the wordmark's cap height, not its ink box,
                    // or the g's descender hangs the word low.
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

/// The secondary jellyfish. Brand rule: only in loading, empty or
/// atmospheric moments, small, one-color and low contrast.
struct LagoonJellyfishAccent: View {
    var body: some View {
        Image("LagoonJellyfish")
            .renderable(template: true)
            .scaledToFit()
            .frame(height: Metrics.jellyfishAccentHeight)
            .foregroundStyle(Theme.accent.opacity(0.35))
            .accessibilityHidden(true)
    }
}

private extension Image {
    func renderable(template: Bool) -> some View {
        renderingMode(template ? .template : .original).resizable()
    }
}

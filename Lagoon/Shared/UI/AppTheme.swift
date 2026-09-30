import Observation
import SwiftUI

/// Lagoon's themes. Each is a whole palette; screens ask `Theme` for colours
/// and never check which theme is on. Keep the list short: every theme is
/// checked over every screen.
nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case lagoon
    case babyPink
    case spooky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lagoon: String(localized: "Lagoon")
        case .babyPink: String(localized: "Baby Pink")
        case .spooky: String(localized: "Spooky")
        }
    }

    var settingsDescription: String {
        switch self {
        case .lagoon:
            String(localized: "The Twin Shores palette: aqua accents over deep navy and black.")
        case .babyPink:
            String(localized: "Soft pink accents over a deep rose ground. Still Lagoon, only prettier.")
        case .spooky:
            String(localized: "Pumpkin orange over midnight, with cobwebs in the corners and a ghost or two. Still Lagoon, only haunted.")
        }
    }

    var palette: ThemePalette {
        switch self {
        case .lagoon: .lagoon
        case .babyPink: .babyPink
        case .spooky: .spooky
        }
    }

    /// What drifts up through the bloom when this theme is chosen.
    var bloomMotif: BloomMotif {
        switch self {
        case .lagoon: .jellyfish
        case .babyPink: .flowers
        case .spooky: .ghosts
        }
    }

    /// What a profile on the default theme wears this month: Spooky in
    /// October, nothing otherwise.
    static func seasonal(on date: Date) -> AppTheme? {
        Calendar.current.component(.month, from: date) == 10 ? .spooky : nil
    }

    /// Cobwebs in the page corners and a ghost in loading and empty states.
    var isHaunted: Bool { self == .spooky }
}

/// The roles a theme fills. A theme colours brand moments (progress,
/// selection, glow, ground), never text. A nil role means the system default.
nonisolated struct ThemePalette: Equatable, Sendable {
    /// The one bright colour: progress fills, selection marks, the jellyfish.
    let accent: Color
    /// The brand's ground, used as a wash over the background.
    let ground: Color
    /// The surface behind all content.
    let background: Color
    /// Grouped form rows, one step lighter than `background`. Nil keeps the
    /// system grey, which only suits a black page.
    let surface: Color?
    /// A third glow colour, for the ambient field behind heroes.
    let glowDepth: Color
    /// Tint for iOS native controls. Nil keeps the white `AccentColor`. Keep
    /// it pale: it fills whole toggle tracks.
    let controlTint: Color?
    /// Blushed into every artwork glow and focus halo. Nil leaves sampled
    /// colours as they are.
    let artworkTint: Color?
    /// A wash behind iOS's bar glass. Keep it faint, or the glass turns into
    /// a flat pane. Nil keeps the system glass. Never applied on tvOS.
    let chrome: Color?

    /// The ambient glow when no artwork has been sampled yet.
    var glow: ArtworkPalette {
        ArtworkPalette(colors: [accent, ground, glowDepth])
    }

    /// How far an artwork colour moves toward `artworkTint`.
    static let artworkTintAmount = 0.45

    /// The brand accent lifted toward white, pale enough to fill a toggle.
    static let paleAqua = Color.lagoonAqua.mix(with: .white, by: 0.4)

    func glow(for artwork: ArtworkPalette) -> ArtworkPalette {
        guard let artworkTint else { return artwork }
        return ArtworkPalette(colors: artwork.colors.map { $0.mix(with: artworkTint, by: Self.artworkTintAmount) })
    }

    /// Twin Shores. Anything that must never follow a theme uses
    /// `Color.lagoonAqua` and `.lagoonNavy` directly.
    static let lagoon = ThemePalette(
        accent: .lagoonAqua,
        ground: .lagoonNavy,
        background: .black,
        surface: nil,
        glowDepth: Color(red: 0.16, green: 0.1, blue: 0.35),
        controlTint: paleAqua,
        artworkTint: nil,
        chrome: nil
    )

    /// Baby pink accent over deep rose.
    static let babyPink = ThemePalette(
        accent: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        ground: Color(red: 0x5E / 255, green: 0x28 / 255, blue: 0x48 / 255),
        background: Color(red: 0x1F / 255, green: 0x10 / 255, blue: 0x19 / 255),
        surface: Color(red: 0x33 / 255, green: 0x18 / 255, blue: 0x2A / 255),
        glowDepth: Color(red: 0x8C / 255, green: 0x4A / 255, blue: 0x72 / 255),
        controlTint: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        artworkTint: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        chrome: Color(red: 0x5E / 255, green: 0x28 / 255, blue: 0x48 / 255).opacity(0.25)
    )
}

extension ThemePalette {
    /// Pumpkin orange over a midnight aubergine, with a purple glow.
    static let spooky = ThemePalette(
        accent: Color(red: 0xFF / 255, green: 0x8C / 255, blue: 0x1A / 255),
        ground: Color(red: 0x2B / 255, green: 0x14 / 255, blue: 0x33 / 255),
        background: Color(red: 0x11 / 255, green: 0x0B / 255, blue: 0x14 / 255),
        surface: Color(red: 0x21 / 255, green: 0x15 / 255, blue: 0x2A / 255),
        glowDepth: Color(red: 0x5C / 255, green: 0x2E / 255, blue: 0x91 / 255),
        controlTint: Color(red: 0xFF / 255, green: 0xB8 / 255, blue: 0x70 / 255),
        // Purple: an orange blush turned every page brown.
        artworkTint: Color(red: 0x5C / 255, green: 0x2E / 255, blue: 0x91 / 255),
        chrome: Color(red: 0x2B / 255, green: 0x14 / 255, blue: 0x33 / 255).opacity(0.25)
    )

    /// A ghost is white, warmed a little by the accent.
    var ghost: Color { Color.white.mix(with: accent, by: 0.12) }
}

/// Which theme is on. The choice belongs to the Jellyfin profile, not the
/// device; `SessionStore` points the store at the active account. While
/// nobody is active, the last profile's theme stays up.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var theme: AppTheme = .lagoon
    private(set) var accountID: String?
    /// Bumped when the bloom should play: the viewer chose a theme, or
    /// switched from one profile to another, which then arrives in its own
    /// theme. Never at launch, and never by returning to the same profile.
    private(set) var bloomCount = 0
    private let defaults: UserDefaults
    private let now: () -> Date
    @ObservationIgnored private var activeOwner: ObjectIdentifier?
    /// The last profile pointed at, kept through the picker's nil.
    @ObservationIgnored private var lastAccountID: String?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    /// Points the store at a profile, or at none (keeps the current theme,
    /// stops saving).
    ///
    /// SwiftUI can construct a root state object more than once, and the
    /// extra `SessionStore`s announce a nil account. So a nil only counts
    /// from the `owner` that activated the current account (as in
    /// `DownloadStore`).
    func configure(accountID: String?, owner: ObjectIdentifier? = nil) {
        if accountID == nil, let activeOwner, owner != activeOwner { return }
        if accountID != nil { activeOwner = owner }
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        guard let accountID else { return }
        theme = Self.theme(for: accountID, in: defaults, on: now())
        if let lastAccountID, lastAccountID != accountID { bloomCount &+= 1 }
        lastAccountID = accountID
    }

    func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        bloomCount &+= 1
        guard let accountID else { return }
        defaults.set(theme.rawValue, forKey: Self.key(accountID))
        // Lagoon chosen in October keeps Lagoon until next October.
        if theme == .lagoon, AppTheme.seasonal(on: now()) != nil {
            defaults.set(Self.year(of: now()), forKey: Self.seasonKey(accountID))
        }
    }

    /// Follows the month turning while the app ran. No bloom.
    func refreshSeason() {
        guard let accountID else { return }
        let resolved = Self.theme(for: accountID, in: defaults, on: now())
        if resolved != theme { theme = resolved }
    }

    /// The saved choice, or the seasonal theme for a profile on the default
    /// that has not declined it this year.
    static func theme(for accountID: String, in defaults: UserDefaults, on date: Date) -> AppTheme {
        let saved = storedTheme(for: accountID, in: defaults)
        guard saved == .lagoon, let seasonal = AppTheme.seasonal(on: date),
              defaults.integer(forKey: seasonKey(accountID)) != year(of: date) else { return saved }
        return seasonal
    }

    private static func year(of date: Date) -> Int {
        Calendar.current.component(.year, from: date)
    }

    /// The saved theme, or `.lagoon` when none or unknown.
    static func storedTheme(for accountID: String?, in defaults: UserDefaults) -> AppTheme {
        guard let accountID, let raw = defaults.string(forKey: key(accountID)) else { return .lagoon }
        return AppTheme(rawValue: raw) ?? .lagoon
    }

    nonisolated static let keyPrefix = "appearance.theme."
    /// The year a profile chose the default during the season.
    nonisolated static let seasonKeyPrefix = "appearance.seasonDeclined."

    static func key(_ accountID: String) -> String {
        keyPrefix + accountID
    }

    static func seasonKey(_ accountID: String) -> String {
        seasonKeyPrefix + accountID
    }
}

/// The current theme's colours. Reading them in a body registers with
/// Observation, so views re-render on a theme change.
enum Theme {
    static var current: AppTheme { ThemeStore.shared.theme }
    static var palette: ThemePalette { ThemeStore.shared.theme.palette }
    static var accent: Color { palette.accent }
    static var ground: Color { palette.ground }
    static var background: Color { palette.background }
    static var surface: Color? { palette.surface }
    static var glow: ArtworkPalette { palette.glow }

    /// The theme's own glow until artwork is sampled.
    static func glow(for artwork: ArtworkPalette?) -> ArtworkPalette {
        guard let artwork, artwork != .fallback else { return palette.glow }
        return palette.glow(for: artwork)
    }
}

/// Behind every page: the theme's background, and its cobwebs, spiders and
/// passing ghosts when it is haunted.
struct ThemePageBackground: View {
    var body: some View {
        ZStack(alignment: .top) {
            Theme.background
            if Theme.current.isHaunted { HauntedDecoration() }
        }
        .ignoresSafeArea()
    }
}

/// A small ghost bobbing above a loading or empty state's glyph, when the
/// theme is haunted. Still under Reduce Motion.
struct ThemeStateGhost: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if Theme.current.isHaunted {
            let color = Theme.palette.ghost
            TimelineView(.animation(paused: reduceMotion)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate / Motion.ghostBob * 2 * .pi
                Canvas { context, size in
                    let height = size.height * 0.88
                    let width = height * GhostGeometry.aspect
                    let lift = reduceMotion ? 0 : (sin(phase) + 1) / 2 * (size.height - height)
                    let rect = CGRect(x: (size.width - width) / 2, y: size.height - height - lift, width: width, height: height)
                    context.fill(
                        GhostGeometry.path(in: rect, wave: reduceMotion ? 0 : phase * 2),
                        with: .color(color.opacity(0.85)),
                        style: GhostGeometry.fillStyle
                    )
                }
            }
            .frame(width: Metrics.stateGhostSize, height: Metrics.stateGhostSize)
            .accessibilityHidden(true)
        }
    }
}

extension View {
    func themedPageBackground() -> some View {
        background { ThemePageBackground() }
    }
}

/// The container for every settings-style form on iOS, so all forms follow
/// the theme.
#if !os(tvOS)
struct ThemedForm<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form { content.listRowBackground(Theme.surface) }
            .scrollContentBackground(.hidden)
            .themedPageBackground()
            .themedChrome()
    }
}
#endif

extension View {
    /// The theme's chrome wash on iOS bars; apply on each tab's root. Not on
    /// tvOS: never tint labels there (see docs/design-system.md).
    @ViewBuilder
    func themedChrome() -> some View {
        #if os(iOS)
        if let chrome = Theme.palette.chrome {
            toolbarBackground(chrome, for: .tabBar, .navigationBar)
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// The theme's tint on iOS native controls. Not on tvOS: a tinted label
    /// in the white focused lozenge is unreadable.
    func themedControls() -> some View {
        #if os(iOS)
        tint(Theme.palette.controlTint)
        #else
        self
        #endif
    }
}

import Observation
import SwiftUI

/// Lagoon's themes. Each is a whole palette; screens ask `Theme` for colours
/// and never check which theme is on. Keep the list short: every theme is
/// checked over every screen.
nonisolated enum AppTheme: String, CaseIterable, Identifiable {
    case lagoon
    case babyPink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lagoon: String(localized: "Lagoon")
        case .babyPink: String(localized: "Baby Pink")
        }
    }

    var settingsDescription: String {
        switch self {
        case .lagoon:
            String(localized: "The Twin Shores palette: aqua accents over deep navy and black.")
        case .babyPink:
            String(localized: "Soft pink accents over a deep rose ground. Still Lagoon, only prettier.")
        }
    }

    var palette: ThemePalette {
        switch self {
        case .lagoon: .lagoon
        case .babyPink: .babyPink
        }
    }

    /// What drifts up through the bloom when this theme is chosen.
    var bloomMotif: BloomMotif {
        switch self {
        case .lagoon: .jellyfish
        case .babyPink: .flowers
        }
    }
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

/// Which theme is on. The choice belongs to the Jellyfin profile, not the
/// device; `SessionStore` points the store at the active account. While
/// nobody is active, the last profile's theme stays up.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var theme: AppTheme = .lagoon
    private(set) var accountID: String?
    /// Bumped only by the viewer's choice, never by loading a saved one, so
    /// the bloom doesn't play on account switches.
    private(set) var selectionCount = 0
    private let defaults: UserDefaults
    @ObservationIgnored private var activeOwner: ObjectIdentifier?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
        theme = Self.storedTheme(for: accountID, in: defaults)
    }

    func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        selectionCount &+= 1
        guard let accountID else { return }
        defaults.set(theme.rawValue, forKey: Self.key(accountID))
    }

    /// The saved theme, or `.lagoon` when none or unknown.
    static func storedTheme(for accountID: String?, in defaults: UserDefaults) -> AppTheme {
        guard let accountID, let raw = defaults.string(forKey: key(accountID)) else { return .lagoon }
        return AppTheme(rawValue: raw) ?? .lagoon
    }

    nonisolated static let keyPrefix = "appearance.theme."

    static func key(_ accountID: String) -> String {
        keyPrefix + accountID
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
            .background(Theme.background.ignoresSafeArea())
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

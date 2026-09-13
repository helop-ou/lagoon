import Observation
import SwiftUI

/// The looks Lagoon can wear (HEL-173). One of them is the brand's own; the
/// other is for the partners who love pink. Each is a whole palette, so a
/// screen never has to know which theme is on: it asks `Theme` for the
/// accent, the ground or the background and gets the current answer.
///
/// Deliberately a short list. A theme is a considered set of five colours
/// that has been checked over every screen, not a hue slider, and the guide
/// says not to go overboard with them.
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
            String(localized: "Soft pink accents over a deep plum ground. Still Lagoon, only prettier.")
        }
    }

    var palette: ThemePalette {
        switch self {
        case .lagoon: .lagoon
        case .babyPink: .babyPink
        }
    }
}

/// The five roles a theme fills. Everything else on screen stays the
/// system's semantic styles, so a theme colours the brand's own moments
/// (progress, selection, the jellyfish, the ambient glow, the ground the
/// content sits on) and never the text.
nonisolated struct ThemePalette: Equatable, Sendable {
    /// The one bright colour: progress fills, selection marks, the jellyfish.
    let accent: Color
    /// The brand's ground, used as a wash over the background.
    let ground: Color
    /// The surface behind all content. True black for the brand; the pink
    /// theme lifts it to a plum so the whole app reads as its own.
    let background: Color
    /// A third glow colour, for the ambient field behind heroes.
    let glowDepth: Color
    /// The tint for iOS's native controls (toggles, pickers, links, the
    /// selected tab). Nil keeps the system's white, which is the brand's
    /// choice: `AccentColor` is white, not a brand colour.
    let controlTint: Color?
    /// Blushed into every artwork glow and focus halo, so the theme is felt
    /// behind a hero and under a lifted card and not only in its own chrome.
    /// Nil leaves artwork colours as sampled, which is the brand's choice.
    let artworkTint: Color?
    /// A wash behind iOS's tab bar and navigation bar glass, so the chrome
    /// belongs to the theme and not to the system's grey. Nil keeps the
    /// system glass. tvOS is never washed: its bar is a focusable control.
    let chrome: Color?

    /// The ambient glow when no artwork has been sampled yet.
    var glow: ArtworkPalette {
        ArtworkPalette(colors: [accent, ground, glowDepth])
    }

    /// How far an artwork colour moves toward `artworkTint`.
    static let artworkTintAmount = 0.45

    /// The glow for a piece of artwork under this theme: the sampled
    /// colours, blushed toward the theme's tint when it has one.
    func glow(for artwork: ArtworkPalette) -> ArtworkPalette {
        guard let artworkTint else { return artwork }
        return ArtworkPalette(colors: artwork.colors.map { $0.mix(with: artworkTint, by: Self.artworkTintAmount) })
    }

    /// Twin Shores. The values match `Color.lagoonAqua` and `.lagoonNavy`,
    /// which stay as the brand's named colours for the lockup and anything
    /// that must never follow a theme.
    static let lagoon = ThemePalette(
        accent: .lagoonAqua,
        ground: .lagoonNavy,
        background: .black,
        glowDepth: Color(red: 0.16, green: 0.1, blue: 0.35),
        controlTint: nil,
        artworkTint: nil,
        chrome: nil
    )

    /// Baby pink over rose. The accent is pale enough to read as baby pink
    /// and bright enough to carry a progress bar on a dark ground; the
    /// ground and background are deep rose rather than pink, so every page
    /// carries the hue without any of them shouting, and artwork glows are
    /// blushed with the accent so a hero never hides the theme.
    static let babyPink = ThemePalette(
        accent: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        ground: Color(red: 0x5E / 255, green: 0x28 / 255, blue: 0x48 / 255),
        background: Color(red: 0x1F / 255, green: 0x10 / 255, blue: 0x19 / 255),
        glowDepth: Color(red: 0x8C / 255, green: 0x4A / 255, blue: 0x72 / 255),
        controlTint: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        artworkTint: Color(red: 0xFF / 255, green: 0xB7 / 255, blue: 0xCF / 255),
        chrome: Color(red: 0x5E / 255, green: 0x28 / 255, blue: 0x48 / 255).opacity(0.7)
    )
}

/// Which theme is on, and for whom. The choice belongs to the Jellyfin
/// profile, not the device: a partner's pink follows their account and
/// nobody else's (HEL-173). `RootView` points the store at the active
/// account; before sign-in the brand theme shows.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()

    private(set) var theme: AppTheme = .lagoon
    private(set) var accountID: String?
    /// Bumped by every change the viewer makes, never by loading a saved
    /// choice, so the activation bloom plays for a decision and not for
    /// switching accounts.
    private(set) var selectionCount = 0
    private let defaults: UserDefaults
    @ObservationIgnored private var activeOwner: ObjectIdentifier?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Points the store at a profile, or at none. `owner` identifies the
    /// session store making the call: SwiftUI can construct a root view's
    /// state object more than once and keep only the first, and every
    /// extra `SessionStore` restores nothing and announces a nil account.
    /// Such a call must not undo the theme the real store loaded, so a nil
    /// configure only counts from the owner that activated the current
    /// account (the same rule `DownloadStore` follows).
    func configure(accountID: String?, owner: ObjectIdentifier? = nil) {
        if accountID == nil, let activeOwner, owner != activeOwner { return }
        if accountID != nil { activeOwner = owner }
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        theme = Self.storedTheme(for: accountID, in: defaults)
    }

    func select(_ theme: AppTheme) {
        guard theme != self.theme else { return }
        self.theme = theme
        selectionCount &+= 1
        guard let accountID else { return }
        defaults.set(theme.rawValue, forKey: Self.key(accountID))
    }

    /// The saved theme for a profile, or the brand's when there is none or
    /// the saved value is one this build does not know.
    static func storedTheme(for accountID: String?, in defaults: UserDefaults) -> AppTheme {
        guard let accountID, let raw = defaults.string(forKey: key(accountID)) else { return .lagoon }
        return AppTheme(rawValue: raw) ?? .lagoon
    }

    static let keyPrefix = "appearance.theme."

    static func key(_ accountID: String) -> String {
        keyPrefix + accountID
    }
}

/// The current theme's colours, for call sites. Reading these inside a
/// view's body registers the theme with Observation, so a change re-renders
/// the view; no environment plumbing needed.
enum Theme {
    static var current: AppTheme { ThemeStore.shared.theme }
    static var palette: ThemePalette { ThemeStore.shared.theme.palette }
    static var accent: Color { palette.accent }
    static var ground: Color { palette.ground }
    static var background: Color { palette.background }
    static var glow: ArtworkPalette { palette.glow }

    /// The glow behind artwork: the theme's own while nothing is sampled
    /// (or sampling failed), otherwise the artwork's colours under the
    /// theme's blush.
    static func glow(for artwork: ArtworkPalette?) -> ArtworkPalette {
        guard let artwork, artwork != .fallback else { return palette.glow }
        return palette.glow(for: artwork)
    }
}

extension View {
    /// iOS's tab bar and navigation bar glass take the theme's chrome wash.
    /// Applied to each tab's root screen, where the bars belong. The brand
    /// theme sets none. tvOS is left alone: `toolbarBackground` does not
    /// reach its bar, and tinting its labels is the failure the design
    /// guide warns about.
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

    /// iOS's native controls take the theme's tint: toggles, pickers, links
    /// and the selected tab. The brand theme sets none, keeping the white
    /// `AccentColor`. tvOS is left alone: its focused glass lozenge is
    /// white, and a tinted label inside it is the failure the design guide
    /// warns about.
    func themedControls() -> some View {
        #if os(iOS)
        tint(Theme.palette.controlTint)
        #else
        self
        #endif
    }
}

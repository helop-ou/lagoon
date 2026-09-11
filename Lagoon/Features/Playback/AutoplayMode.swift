import Foundation

/// What the player does when an episode runs out (HEL-66).
///
/// Jaagop's three, 2026-08-18. Deliberately shaped like `SkipMode` — same
/// row in Settings, same countdown length — so the two playback decisions
/// read as a pair rather than as two unrelated features that happen to
/// share a screen.
nonisolated enum AutoplayMode: String, CaseIterable, Identifiable {
    /// The card appears with a fill that runs down, then the next episode
    /// starts on its own. Back/Menu during that window means "no".
    case autoDelay
    /// The card appears but never acts alone; Select starts the next one.
    case card
    /// No card. The player closes at the end of an episode, as it always did.
    case off

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .autoDelay: "Play Automatically"
        case .card: "Ask Every Time"
        case .off: "Off"
        }
    }

    /// Compact form for a settings row's value column, where the row's own
    /// label already says what the setting is.
    var shortTitle: String {
        switch self {
        case .autoDelay: String(localized: "Automatic")
        case .card: String(localized: "Ask")
        case .off: String(localized: "Off")
        }
    }

    /// Matches `SkipMode.autoDelaySeconds` on purpose (Jaagop, 2026-08-18):
    /// two countdowns in the same player running at different speeds would
    /// read as a bug rather than as two settings.
    static let countdownSeconds: Double = 5
}

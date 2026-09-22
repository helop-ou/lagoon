import Foundation
import LagoonEngine

/// What the player does when an episode runs out. Shaped like `SkipMode` so
/// the two settings read as a pair.
nonisolated enum AutoplayMode: String, CaseIterable, Identifiable {
    /// The card counts down, then the next episode starts. Back/Menu means "no".
    case autoDelay
    /// The card appears but never acts alone; Select starts the next one.
    case card
    /// No card. The player closes at the end of an episode.
    case off

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .autoDelay: "Play Automatically"
        case .card: "Ask Every Time"
        case .off: "Off"
        }
    }

    /// Compact form for a settings row's value column.
    var shortTitle: String {
        switch self {
        case .autoDelay: String(localized: "Automatic")
        case .card: String(localized: "Ask")
        case .off: String(localized: "Off")
        }
    }

    /// Matches `SkipMode.autoDelaySeconds`: two countdowns at different speeds
    /// would read as a bug.
    static let countdownSeconds: Double = 5

    static let defaultsKey = "playback.autoplayMode"
}

import Foundation
import LagoonEngine

/// How the player treats a skippable intro or recap. No "off": an ignored
/// *button* skips nothing.
nonisolated enum SkipMode: String, CaseIterable, Identifiable {
    /// Show the button with a countdown fill, then skip. Back/Menu cancels.
    case autoDelay
    /// No button; skip the instant the segment is entered.
    case instant
    /// The button waits for confirmation and never acts alone.
    case button

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .autoDelay: "Skip Automatically"
        case .instant: "Skip Instantly"
        case .button: "Ask Every Time"
        }
    }

    /// Compact form for a settings row's value column.
    var shortTitle: String {
        switch self {
        case .autoDelay: String(localized: "Automatic")
        case .instant: String(localized: "Instant")
        case .button: String(localized: "Ask")
        }
    }

    static let autoDelaySeconds: Double = 5

    static let defaultsKey = "playback.skipMode"
}

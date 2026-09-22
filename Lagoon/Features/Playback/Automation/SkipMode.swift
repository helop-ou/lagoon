import Foundation
import LagoonEngine

/// How the player treats a skippable segment — intro or recap.
///
/// Three modes. There is no "off": *button* already covers
/// wanting nothing to happen, because an ignored button skips nothing.
nonisolated enum SkipMode: String, CaseIterable, Identifiable {
    /// Show the button with a fill that runs down, then skip on its own.
    /// Back/Menu during that window means "no", and cancels it.
    case autoDelay
    /// No button; the segment is skipped the instant it is entered.
    case instant
    /// The button waits for an explicit confirmation and never acts alone.
    case button

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .autoDelay: "Skip Automatically"
        case .instant: "Skip Instantly"
        case .button: "Ask Every Time"
        }
    }

    /// Compact form for a settings row's value column, where the row's own
    /// label already says what the setting is.
    var shortTitle: String {
        switch self {
        case .autoDelay: String(localized: "Automatic")
        case .instant: String(localized: "Instant")
        case .button: String(localized: "Ask")
        }
    }

    /// How long the fill takes before `autoDelay` commits.
    static let autoDelaySeconds: Double = 5

    /// Where Settings keeps the choice; the player reads it there too.
    static let defaultsKey = "playback.skipMode"
}

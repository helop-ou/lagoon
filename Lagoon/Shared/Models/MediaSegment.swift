import Foundation

/// A classified stretch of the item: intro, recap, credits.
nonisolated struct MediaSegment: Identifiable, Equatable {
    /// The segment type, with Jellyfin's `MediaSegmentType` strings as raw
    /// values. Only `intro` and `recap` are skippable: real films carry
    /// `commercial` segments mid-movie, and an `outro` hands off to the next
    /// episode instead.
    enum Kind: String {
        case intro = "Intro"
        case outro = "Outro"
        case recap = "Recap"
        case preview = "Preview"
        case commercial = "Commercial"
        case other

        var isSkippable: Bool { self == .intro || self == .recap }

        /// The skip button's title.
        var skipTitle: String {
            self == .recap ? String(localized: "Skip Recap") : String(localized: "Skip Intro")
        }
    }

    let id: String
    let kind: Kind
    let start: Double
    let end: Double

    func contains(_ seconds: Double) -> Bool {
        seconds >= start && seconds < end
    }
}

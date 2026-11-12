import Foundation

/// The previous and next buttons in the player itself: beside the iOS centre
/// cluster, and in the tvOS row above the scrubber.
nonisolated struct PlayerEpisodeButtons: Equatable {
    let hasPrevious: Bool
    let hasNext: Bool

    /// Nil when neither side has a title, and in a Watch Together group,
    /// where changing the item is the group's to do.
    static func offered(hasPrevious: Bool, hasNext: Bool, inGroup: Bool) -> PlayerEpisodeButtons? {
        guard !inGroup, hasPrevious || hasNext else { return nil }
        return PlayerEpisodeButtons(hasPrevious: hasPrevious, hasNext: hasNext)
    }
}

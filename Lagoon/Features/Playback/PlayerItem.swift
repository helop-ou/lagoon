import Foundation

/// Identifiable wrapper so `fullScreenCover(item:)` can present playback.
nonisolated struct PlayerItem: Identifiable {
    let id = UUID()
    let media: MediaItem
    var startFromBeginning = false
    /// Where to start, outranking every resume rule. Set by a SyncPlay
    /// group, which knows where everyone else already is (HEL-172); nil
    /// everywhere else, so the ordinary resume logic decides.
    var startPosition: Double?
    /// Load and sit on the first frame instead of rolling. A group member
    /// primes, reports Ready, and is started later at an instant the whole
    /// group agreed on.
    var startPaused = false
    /// The group's handle for this queue entry, carried so the presenting
    /// layer can tell one group item from the next.
    var groupPlaylistItemId: String?
}

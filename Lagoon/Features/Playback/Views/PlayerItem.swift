import Foundation
import LagoonEngine

/// Identifiable wrapper so `fullScreenCover(item:)` can present playback.
nonisolated struct PlayerItem: Identifiable {
    let id = UUID()
    let media: MediaItem
    var startFromBeginning = false
    /// Overrides every resume rule. Set only by a SyncPlay group.
    var startPosition: Double?
    /// Hold on the first frame; a group member starts at the agreed instant.
    var startPaused = false
    /// Tells one group queue entry from the next.
    var groupPlaylistItemId: String?
}

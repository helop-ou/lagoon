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
    /// What follows `media`. In a list queue, `media` is the current entry.
    var queue: PlayQueue = .series
}

nonisolated extension PlayerItem {
    /// Plays a list from its current entry.
    init(list: PlayQueueList, startFromBeginning: Bool = false) {
        self.init(media: list.current.media, startFromBeginning: startFromBeginning, queue: .list(list))
    }
}

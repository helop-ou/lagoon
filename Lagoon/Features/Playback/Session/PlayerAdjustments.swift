import Foundation
import LagoonEngine

/// Adjustments the player panel makes that outlive one engine: a fallback
/// rung, an episode handoff or a replay of the same item keeps them.
///
/// Closures rather than a controller reference, as `PlayerTransportActions`.
struct PlayerAdjustments {
    let setSubtitleOffset: (_ seconds: Double) -> Void
}

/// Subtitle offsets the viewer set, by item, while the app runs. An offset
/// fixes a subtitle file that is out of step, not one viewing, so reopening
/// the item keeps it.
nonisolated struct SubtitleOffsetMemory {
    private var offsets: [String: Double] = [:]

    mutating func remember(_ seconds: Double, for itemID: String) {
        guard !itemID.isEmpty else { return }
        offsets[itemID] = seconds == 0 ? nil : seconds
    }

    func offset(for itemID: String) -> Double {
        offsets[itemID] ?? 0
    }
}

/// The subtitle offset of whatever plays. It follows the engine the
/// controller last made, so the panel's change reaches that engine and is
/// kept for the item it plays.
@MainActor
final class PlayerSubtitleOffset {
    /// For the app's lifetime, across players: see `SubtitleOffsetMemory`.
    private static var memory = SubtitleOffsetMemory()
    private weak var engine: (any PlayerEngine)?
    private var itemID = ""

    /// A new engine for the item starts in step with what the viewer set.
    func attach(_ engine: any PlayerEngine, itemID: String) {
        self.engine = engine
        self.itemID = itemID
        let seconds = Self.memory.offset(for: itemID)
        if seconds != 0 {
            engine.setSubtitleOffset(seconds)
        }
    }

    /// Kept as the engine settled it, since the engine bounds an offset.
    func set(_ seconds: Double) {
        guard let engine else { return }
        engine.setSubtitleOffset(seconds)
        Self.memory.remember(engine.subtitleOffset, for: itemID)
    }
}

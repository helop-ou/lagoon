import Foundation

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

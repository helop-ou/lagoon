import Foundation

/// The decisions behind `serverRefreshable`, kept apart from SwiftUI: when a
/// destination may refresh, and which refresh a change asks for. A hidden
/// tab never polls, and a bump it missed while hidden is replayed once.
nonisolated struct ServerRefreshGate {
    /// What the caller and the scene allow, besides visibility.
    struct Conditions: Equatable {
        var isActive: Bool
        var isEnabled: Bool
        var isPaused: Bool
        var sceneIsActive: Bool
    }

    private(set) var isVisible = false
    // Baselined on first appearance, so a bump that arrives while hidden
    // is replayed when the tab comes back.
    private(set) var handledGeneration: Int?

    func canRefresh(_ conditions: Conditions) -> Bool {
        conditions.isActive && conditions.isEnabled && !conditions.isPaused
            && conditions.sceneIsActive && isVisible
    }

    mutating func appear(generation: Int) {
        isVisible = true
        if handledGeneration == nil { handledGeneration = generation }
    }

    mutating func disappear() {
        isVisible = false
    }

    /// Refresh just became possible. True, and the generation is taken,
    /// when the shared clock advanced while it was not.
    mutating func replaysMissedGeneration(_ generation: Int, _ conditions: Conditions) -> Bool {
        guard canRefresh(conditions), let handled = handledGeneration, generation > handled else { return false }
        handledGeneration = generation
        return true
    }

    /// The shared clock advanced. True, and the generation is taken, when
    /// this destination may refresh now; otherwise it waits to be replayed.
    mutating func takesGeneration(_ generation: Int, _ conditions: Conditions) -> Bool {
        guard canRefresh(conditions) else { return false }
        handledGeneration = generation
        return true
    }

    /// A manual refresh belongs only to the destination it was asked for.
    func takesManualRefresh(for requested: ServerSyncTarget?, as target: ServerSyncTarget, _ conditions: Conditions) -> Bool {
        canRefresh(conditions) && requested == target
    }
}

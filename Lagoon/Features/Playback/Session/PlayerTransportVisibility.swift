/// Whether the touch player's transport, centre buttons and toolbar are up.
nonisolated struct PlayerTransportVisibility {
    /// A tap brought them up and four idle seconds have not passed.
    var isRevealed: Bool
    var voiceOver: Bool
    var isPaused: Bool
    var isScrubbing: Bool
    /// Across a fold the controls have a side of their own, with no picture
    /// under them to uncover.
    var isFoldSplit: Bool
    var panelOpen: Bool

    var isVisible: Bool {
        (isRevealed || voiceOver || isPaused || isScrubbing || isFoldSplit) && !panelOpen
    }
}

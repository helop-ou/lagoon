import Testing
@testable import Lagoon

/// The touch player's controls fade while a title plays, unless something
/// keeps them up.
@Suite("Player transport visibility")
struct PlayerTransportVisibilityTests {
    private func visibility(
        isRevealed: Bool = false,
        voiceOver: Bool = false,
        isPaused: Bool = false,
        isScrubbing: Bool = false,
        isFoldSplit: Bool = false,
        panelOpen: Bool = false
    ) -> PlayerTransportVisibility {
        PlayerTransportVisibility(
            isRevealed: isRevealed,
            voiceOver: voiceOver,
            isPaused: isPaused,
            isScrubbing: isScrubbing,
            isFoldSplit: isFoldSplit,
            panelOpen: panelOpen
        )
    }

    @Test func aTitlePlayingUntouchedHidesThem() {
        #expect(!visibility().isVisible)
    }

    @Test func aTapAPauseAScrubOrVoiceOverKeepsThemUp() {
        #expect(visibility(isRevealed: true).isVisible)
        #expect(visibility(voiceOver: true).isVisible)
        #expect(visibility(isPaused: true).isVisible)
        #expect(visibility(isScrubbing: true).isVisible)
    }

    /// A partly folded iPhone Duo gives the controls a side of their own.
    @Test func aFoldKeepsThemUpWhileATitlePlaysUntouched() {
        #expect(visibility(isFoldSplit: true).isVisible)
    }

    @Test func theOptionsPanelHidesThemWhateverElseHolds() {
        #expect(!visibility(isRevealed: true, isPaused: true, isFoldSplit: true, panelOpen: true).isVisible)
    }
}

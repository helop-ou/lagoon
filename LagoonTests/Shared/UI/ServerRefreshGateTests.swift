import Foundation
import Testing
@testable import Lagoon

@Suite("Server refresh gate")
struct ServerRefreshGateTests {
    private let open = ServerRefreshGate.Conditions(isActive: true, isEnabled: true, isPaused: false, sceneIsActive: true)

    @Test func aHiddenDestinationIgnoresABump() {
        var gate = ServerRefreshGate()
        gate.appear(generation: 0)
        gate.disappear()

        let took = gate.takesGeneration(1, open)
        #expect(!took)
        #expect(gate.handledGeneration == 0)
    }

    @Test func aBumpMissedWhileHiddenIsReplayedExactlyOnceOnReturn() {
        var gate = ServerRefreshGate()
        gate.appear(generation: 0)
        gate.disappear()
        let took = gate.takesGeneration(1, open)
        #expect(!took)

        gate.appear(generation: 1)
        let replayed = gate.replaysMissedGeneration(1, open)
        #expect(replayed)
        let replayedAgain = gate.replaysMissedGeneration(1, open)
        #expect(!replayedAgain)
    }

    @Test func theFirstAppearanceIsNotAMissedBump() {
        // The screen's own first load already reads the current server state.
        var gate = ServerRefreshGate()
        gate.appear(generation: 4)

        let replayed = gate.replaysMissedGeneration(4, open)
        #expect(!replayed)
    }

    @Test func aVisibleDestinationTakesEachBumpAsItComes() {
        var gate = ServerRefreshGate()
        gate.appear(generation: 0)

        let took = gate.takesGeneration(1, open)
        #expect(took)
        let replayed = gate.replaysMissedGeneration(1, open)
        #expect(!replayed)
    }

    @Test(arguments: [
        ServerRefreshGate.Conditions(isActive: false, isEnabled: true, isPaused: false, sceneIsActive: true),
        ServerRefreshGate.Conditions(isActive: true, isEnabled: false, isPaused: false, sceneIsActive: true),
        ServerRefreshGate.Conditions(isActive: true, isEnabled: true, isPaused: true, sceneIsActive: true),
        ServerRefreshGate.Conditions(isActive: true, isEnabled: true, isPaused: false, sceneIsActive: false),
    ])
    func anyClosedConditionHoldsTheBumpForLater(blocked: ServerRefreshGate.Conditions) {
        var gate = ServerRefreshGate()
        gate.appear(generation: 0)

        #expect(!gate.canRefresh(blocked))
        let took = gate.takesGeneration(1, blocked)
        #expect(!took)
        let replayed = gate.replaysMissedGeneration(1, open)
        #expect(replayed)
    }

    @Test func aManualRefreshReachesOnlyItsTarget() {
        var gate = ServerRefreshGate()
        #expect(!gate.takesManualRefresh(for: .home, as: .home, open))

        gate.appear(generation: 0)
        #expect(!gate.takesManualRefresh(for: .discover, as: .home, open))
        #expect(!gate.takesManualRefresh(for: nil, as: .home, open))
        #expect(gate.takesManualRefresh(for: .home, as: .home, open))
        #expect(!gate.takesManualRefresh(for: .library("b"), as: .library("a"), open))
    }

    @Test func foregroundingRefreshesOnlyASignedInActiveScene() {
        #expect(ServerSyncState.foregroundAdvancesGeneration(sceneIsActive: true, isSignedIn: true))
        #expect(!ServerSyncState.foregroundAdvancesGeneration(sceneIsActive: true, isSignedIn: false))
        #expect(!ServerSyncState.foregroundAdvancesGeneration(sceneIsActive: false, isSignedIn: true))
    }
}

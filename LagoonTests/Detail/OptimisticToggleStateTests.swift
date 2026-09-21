import Testing
@testable import Lagoon

/// The transitions behind the watched and favourite toggles(A14):
/// optimistic flip, refusal with feedback, and reconciliation with the
/// server after an accepted change.
@Suite("Optimistic toggle state")
struct OptimisticToggleStateTests {
    @Test func aPressFlipsTheIconBeforeTheServerAnswers() {
        var state = OptimisticToggleState()
        #expect(state.value(server: false) == false)
        #expect(state.begin(server: false) == true)
        #expect(state.value(server: false) == true)
        #expect(state.isInFlight)
    }

    @Test func aPressDuringARequestIsDroppedNotQueued() {
        var state = OptimisticToggleState()
        #expect(state.begin(server: false) == true)
        #expect(state.begin(server: false) == nil)
        #expect(state.value(server: false) == true)
        #expect(state.pendingTarget == true)
    }

    @Test func aRefusalRevertsAndSaysWhatWasRefused() {
        var state = OptimisticToggleState()
        _ = state.begin(server: false)
        state.fail()
        #expect(state.value(server: false) == false)
        #expect(!state.isInFlight)
        #expect(state.refusedTarget == true)
        state.dismissFailure()
        #expect(state.refusedTarget == nil)
    }

    @Test func theNextPressClearsAnOldRefusal() {
        var state = OptimisticToggleState()
        _ = state.begin(server: true)
        state.fail()
        #expect(state.refusedTarget == false)
        _ = state.begin(server: true)
        #expect(state.refusedTarget == nil)
    }

    @Test func anAcceptedChangeHandsAuthorityBackOnceTheItemIsReRead() {
        var state = OptimisticToggleState()
        _ = state.begin(server: false)
        state.succeed(refreshed: true)
        #expect(!state.isInFlight)
        #expect(state.override == nil)
        // The server is authoritative now, whatever it says: a change made
        // on another client, or a server that accepted but disagreed, shows.
        #expect(state.value(server: true) == true)
        #expect(state.value(server: false) == false)
    }

    @Test func anAcceptedChangeKeepsTheChoiceWhenTheReReadFailed() {
        var state = OptimisticToggleState()
        _ = state.begin(server: false)
        state.succeed(refreshed: false)
        #expect(!state.isInFlight)
        // The server accepted; the stale item must not flip the icon back.
        #expect(state.value(server: false) == true)
        // A later successful re-read lets the server's value through.
        _ = state.begin(server: false)
        state.succeed(refreshed: true)
        #expect(state.value(server: false) == false)
    }

    @Test func aNewItemDropsEverythingCarriedOver() {
        var state = OptimisticToggleState()
        _ = state.begin(server: false)
        state.fail()
        state.itemChanged()
        #expect(state == OptimisticToggleState())
        #expect(state.value(server: true) == true)
    }

    @Test func togglingTwiceReturnsToTheServersValue() {
        var state = OptimisticToggleState()
        #expect(state.begin(server: false) == true)
        state.succeed(refreshed: false)
        #expect(state.begin(server: false) == false)
        state.succeed(refreshed: false)
        #expect(state.value(server: false) == false)
    }
}

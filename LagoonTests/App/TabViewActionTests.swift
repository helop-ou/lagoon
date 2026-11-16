import Testing
@testable import Lagoon

/// What a screen is handed to ask the tab view for something.
@Suite("Tab view actions")
@MainActor
struct TabViewActionTests {
    @Test func callingOneRunsWhatItWasGiven() {
        var runs = 0
        let action = TabViewAction { runs += 1 }
        action()
        action()
        #expect(runs == 2)
    }

    /// The tab view hands a new one down on every update. If that looked
    /// like a change, every screen reading it would redraw each time.
    @Test func anyTwoCompareEqual() {
        var runs = 0
        #expect(TabViewAction {} == TabViewAction { runs += 1 })
        #expect(runs == 0)
    }
}

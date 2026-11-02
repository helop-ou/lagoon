#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

/// With the bars on the side (a closed iPhone Duo) the Search tab has no
/// field of its own, so selecting the tab must open it.
@Suite("Vertical bar search activation")
struct VerticalBarSearchActivationTests {
    @Test(arguments: [HorizontalEdge.leading, .trailing])
    func sideBarsOpenTheFieldWhenTheTabIsSelected(edge: HorizontalEdge) {
        #expect(VerticalBarSearchActivation.activation(barEdge: edge) == .searchTabSelection)
    }

    /// A bottom tab bar already shows the field, and the keyboard waits for
    /// a tap.
    @Test func aBottomBarLeavesActivationToTheSystem() {
        #expect(VerticalBarSearchActivation.activation(barEdge: nil) == .automatic)
    }
}
#endif

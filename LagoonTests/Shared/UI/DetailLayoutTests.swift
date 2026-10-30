#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

@Suite("Detail layout")
struct DetailLayoutTests {
    /// An open iPhone Duo is regular both ways like an iPad, and must get the
    /// wide layout whatever the device idiom says.
    @Test func regularBothWaysGetsTheWideLayout() {
        #expect(DetailLayout.usesLeadingColumn(.regular, .regular))
    }

    /// A landscape Pro Max is regular wide but compact tall.
    @Test func aLandscapePhoneKeepsThePhoneLayout() {
        #expect(!DetailLayout.usesLeadingColumn(.regular, .compact))
        #expect(DetailLayout.usesLandscapeRow(.regular, .compact))
    }

    @Test func compactWidthKeepsThePhoneLayout() {
        #expect(!DetailLayout.usesLeadingColumn(.compact, .regular))
        #expect(!DetailLayout.usesLandscapeRow(.compact, .regular))
    }
}
#endif

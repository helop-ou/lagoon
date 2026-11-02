#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

/// Layouts follow the size classes, never the device idiom. The suite runs
/// on an iPhone, so an idiom check slipping back fails the wide cases here.
@Suite("Detail layout")
struct DetailLayoutTests {
    /// An open iPhone Duo is regular both ways like an iPad, and must get the
    /// wide layout whatever the device idiom says.
    @Test func regularBothWaysGetsTheWideLayout() {
        #expect(DetailLayout.usesLeadingColumn(.regular, .regular))
        #expect(!DetailLayout.usesLandscapeRow(.regular, .regular))
        #expect(DetailLayout.titleAlignment(.regular, .regular) == .leading)
    }

    /// A landscape Pro Max is regular wide but compact tall.
    @Test func aLandscapePhoneKeepsThePhoneLayout() {
        #expect(!DetailLayout.usesLeadingColumn(.regular, .compact))
        #expect(DetailLayout.usesLandscapeRow(.regular, .compact))
        #expect(DetailLayout.titleAlignment(.regular, .compact) == .leading)
    }

    /// A smaller phone in landscape, and a closed Duo on its side.
    @Test func compactBothWaysIsTheLandscapeRow() {
        #expect(!DetailLayout.usesLeadingColumn(.compact, .compact))
        #expect(DetailLayout.usesLandscapeRow(.compact, .compact))
        #expect(DetailLayout.titleAlignment(.compact, .compact) == .leading)
    }

    /// A portrait phone, a closed Duo, or a narrow split view on either.
    @Test func compactWidthKeepsThePhoneLayout() {
        #expect(!DetailLayout.usesLeadingColumn(.compact, .regular))
        #expect(!DetailLayout.usesLandscapeRow(.compact, .regular))
        #expect(DetailLayout.titleAlignment(.compact, .regular) == .center)
    }

    /// Before the first trait update the size classes can be nil. That must
    /// not pass for wide.
    @Test(arguments: [
        (UserInterfaceSizeClass?.none, UserInterfaceSizeClass?.none),
        (.regular, nil),
        (nil, .regular),
    ])
    func anUnknownSizeClassIsNotWide(horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?) {
        #expect(!DetailLayout.usesLeadingColumn(horizontal, vertical))
        #expect(!DetailLayout.usesLandscapeRow(horizontal, vertical))
        #expect(DetailLayout.titleAlignment(horizontal, vertical) == .center)
    }
}
#endif

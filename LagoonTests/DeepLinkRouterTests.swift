import Foundation
import Testing
@testable import Lagoon

/// The `lagoon://` contract is shared with `LagoonTopShelf/ContentProvider.swift`,
/// which is a separate target that cannot import this one. Nothing but these
/// tests holds the two halves together (HEL-119).
@Suite("Deep links")
struct DeepLinkRouterTests {
    @Test @MainActor func playOpensThePlayer() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://play/abc123")!)
        #expect(router.pendingItemID == "abc123")
        #expect(router.pendingDetailItemID == nil)
    }

    /// The carousel's two buttons must do two different things: Play resumes,
    /// More Info opens the detail page.
    @Test @MainActor func itemOpensTheDetailPage() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://item/abc123")!)
        #expect(router.pendingDetailItemID == "abc123")
        #expect(router.pendingItemID == nil)
    }

    /// A host this build does not know must be ignored rather than guessed
    /// at: acting on it would open something arbitrary.
    @Test @MainActor func anUnknownHostIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://search/abc123")!)
        #expect(router.pendingItemID == nil)
        #expect(router.pendingDetailItemID == nil)
    }

    @Test @MainActor func aForeignSchemeIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "https://play/abc123")!)
        #expect(router.pendingItemID == nil)
        #expect(router.pendingDetailItemID == nil)
    }

    @Test @MainActor func aMissingIdentifierIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://play")!)
        router.handle(URL(string: "lagoon://play/")!)
        #expect(router.pendingItemID == nil)
    }

    /// Jellyfin ids are hex strings, but the router must not assume a shape
    /// it was never promised.
    @Test @MainActor func anIdentifierIsTakenVerbatim() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://item/cf0196f6348ede37f5a02e26e00d9b85")!)
        #expect(router.pendingDetailItemID == "cf0196f6348ede37f5a02e26e00d9b85")
    }

    /// Extra path components are not part of the contract; the first one is
    /// the id and the rest is noise.
    @Test @MainActor func onlyTheFirstPathComponentIsUsed() {
        let router = DeepLinkRouter()
        router.handle(URL(string: "lagoon://play/abc123/extra")!)
        #expect(router.pendingItemID == "abc123")
    }
}

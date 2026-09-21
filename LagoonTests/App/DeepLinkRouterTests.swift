import Foundation
import Testing
@testable import Lagoon

/// The `lagoon://` contract is shared with `LagoonTopShelf/ContentProvider.swift`,
/// which is a separate target that cannot import this one. Nothing but these
/// tests holds the two halves together.
@Suite("Deep links")
struct DeepLinkRouterTests {
    @MainActor private func link(_ value: String) -> URL {
        var components = URLComponents(string: value)!
        components.queryItems = [URLQueryItem(name: "owner", value: String(repeating: "a", count: 64)),
                                 URLQueryItem(name: "generation", value: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")]
        return components.url!
    }

    @Test @MainActor func legacyAndIncompleteOwnershipLinksAreIgnored() {
        let router = DeepLinkRouter()
        for value in ["lagoon://play/abc", "lagoon://play/abc?owner=a", "lagoon://item/abc?generation=bad"] {
            router.handle(URL(string: value)!)
            #expect(router.pendingItemID == nil)
            #expect(router.pendingDetailItemID == nil)
        }
    }

    @Test @MainActor func aNewActionReplacesThePreviousAction() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://play/abc"))
        router.handle(link("lagoon://item/def"))
        #expect(router.pendingItemID == nil)
        #expect(router.pendingDetailItemID == "def")
        #expect(!router.isCurrent(itemID: "def", accountID: "another-account"))
    }

    @Test @MainActor func playOpensThePlayer() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://play/abc123"))
        #expect(router.pendingItemID == "abc123")
        #expect(router.pendingDetailItemID == nil)
    }

    /// The carousel's two buttons must do two different things: Play resumes,
    /// More Info opens the detail page.
    @Test @MainActor func itemOpensTheDetailPage() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://item/abc123"))
        #expect(router.pendingDetailItemID == "abc123")
        #expect(router.pendingItemID == nil)
    }

    /// A host this build does not know must be ignored rather than guessed
    /// at: acting on it would open something arbitrary.
    @Test @MainActor func anUnknownHostIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://search/abc123"))
        #expect(router.pendingItemID == nil)
        #expect(router.pendingDetailItemID == nil)
    }

    @Test @MainActor func aForeignSchemeIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(link("https://play/abc123"))
        #expect(router.pendingItemID == nil)
        #expect(router.pendingDetailItemID == nil)
    }

    @Test @MainActor func aMissingIdentifierIsIgnored() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://play"))
        router.handle(link("lagoon://play/"))
        #expect(router.pendingItemID == nil)
    }

    /// Jellyfin ids are hex strings, but the router must not assume a shape
    /// it was never promised.
    @Test @MainActor func anIdentifierIsTakenVerbatim() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://item/cf0196f6348ede37f5a02e26e00d9b85"))
        #expect(router.pendingDetailItemID == "cf0196f6348ede37f5a02e26e00d9b85")
    }

    /// Extra path components are not part of the contract; the first one is
    /// the id and the rest is noise.
    @Test @MainActor func onlyTheFirstPathComponentIsUsed() {
        let router = DeepLinkRouter()
        router.handle(link("lagoon://play/abc123/extra"))
        #expect(router.pendingItemID == "abc123")
    }
}

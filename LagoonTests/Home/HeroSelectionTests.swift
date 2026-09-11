import Foundation
import Testing
@testable import Lagoon

/// Home's hero fallback order (HEL-147): the first tier with an eligible
/// item supplies the hero, tiers are never mixed to reach six, and a refresh
/// keeps what is on screen wherever the server still returns it.
@Suite("Hero selection")
struct HeroSelectionTests {
    private func item(_ id: String, backdrop: Bool = true, overview: Bool = true, name: String? = nil) throws -> MediaItem {
        var json = #"{"Id":"\#(id)","Type":"Movie","Name":"\#(name ?? id)""#
        if backdrop { json += #","BackdropImageTags":["tag"]"# }
        if overview { json += #","Overview":"About \#(id)""# }
        json += "}"
        return try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    private let keepOrder: ([MediaItem]) -> [MediaItem] = { $0 }

    @Test func onlyItemsWithABackdropAndAnOverviewAreEligible() throws {
        #expect(HeroSelection.isEligible(try item("both")))
        #expect(!HeroSelection.isEligible(try item("no-backdrop", backdrop: false)))
        #expect(!HeroSelection.isEligible(try item("no-overview", overview: false)))
    }

    @Test func recentlyAddedWinsWheneverItHasAnything() throws {
        let latest = [try item("new-1"), try item("new-2")]
        let resume = [try item("watching-1")]
        let hero = HeroSelection.select(tiers: [latest, resume, []], shuffle: keepOrder)
        #expect(hero.map(\.id) == ["new-1", "new-2"], "a leading tier is never topped up from the next one")
    }

    @Test func anEmptyLeadingTierFallsThroughToTheNextWithAnEligibleItem() throws {
        let latestWithoutArtwork = [try item("new-plain", backdrop: false)]
        let resume = [try item("watching-1"), try item("watching-2")]
        let favorites = [try item("favourite-1")]
        let hero = HeroSelection.select(tiers: [latestWithoutArtwork, resume, favorites], shuffle: keepOrder)
        #expect(hero.map(\.id) == ["watching-1", "watching-2"])

        let sample = [try item("random-1")]
        #expect(HeroSelection.select(tiers: [[], [], [], [], sample], shuffle: keepOrder).map(\.id) == ["random-1"])
        #expect(HeroSelection.select(tiers: [[], [], []], shuffle: keepOrder).isEmpty)
    }

    @Test func atMostSixAndNoDuplicates() throws {
        let latest = try (1...9).map { try item("new-\($0)") } + [try item("new-1")]
        let hero = HeroSelection.select(tiers: [latest], shuffle: keepOrder)
        #expect(hero.count == HeroSelection.count)
        #expect(Set(hero.map(\.id)).count == hero.count)
    }

    @Test func shuffleIsApplied() throws {
        let latest = [try item("a"), try item("b"), try item("c")]
        let hero = HeroSelection.select(tiers: [latest], shuffle: { $0.reversed() })
        #expect(hero.map(\.id) == ["c", "b", "a"])
    }

    @Test func aRefreshKeepsWhatIsOnScreenAndFillsFromTheLeadingTier() throws {
        // The hero came from Continue Watching while nothing was added.
        let onScreen = [try item("watching-1", name: "Old record"), try item("watching-2")]
        // Now something has been added, and one watched title has finished.
        let latest = [try item("new-1"), try item("new-2")]
        let resume = [try item("watching-1", name: "Fresh record")]
        let hero = HeroSelection.refreshed(current: onScreen, tiers: [latest, resume])
        #expect(hero.map(\.id) == ["watching-1", "new-1", "new-2"])
        #expect(hero.first?.name == "Fresh record", "the on-screen item takes the server's fresh record")
    }

    @Test func aRefreshWithNothingAnywhereEmptiesTheHero() throws {
        let onScreen = [try item("gone")]
        #expect(HeroSelection.refreshed(current: onScreen, tiers: [[], []]).isEmpty)
    }
}

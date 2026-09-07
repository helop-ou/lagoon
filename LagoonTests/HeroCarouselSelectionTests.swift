import Testing
@testable import Lagoon

@Suite("Hero carousel selection")
struct HeroCarouselSelectionTests {
    private let ids = ["first", "second", "third"]

    @Test func startsAtFirstSlide() {
        let selection = HeroCarouselSelection()
        #expect(selection.currentID(in: ids) == "first")
        #expect(selection.adjacentID(offset: 1, in: ids) == "second")
    }

    @Test func movesBothWaysAndWrapsAtTheEnds() {
        var selection = HeroCarouselSelection()
        selection.select(selection.adjacentID(offset: -1, in: ids), in: ids)
        #expect(selection.currentID(in: ids) == "third")
        selection.select(selection.adjacentID(offset: 1, in: ids), in: ids)
        #expect(selection.currentID(in: ids) == "first")
        selection.select("second", in: ids)
        #expect(selection.adjacentID(offset: -1, in: ids) == "first")
        #expect(selection.adjacentID(offset: 1, in: ids) == "third")
    }

    @Test func emptyAndSingleSlideAreSafe() {
        var selection = HeroCarouselSelection()
        #expect(selection.currentID(in: []) == nil)
        #expect(selection.adjacentID(offset: 1, in: []) == nil)
        #expect(selection.adjacentID(offset: -1, in: []) == nil)
        #expect(selection.adjacentID(offset: 1, in: ["only"]) == "only")
        #expect(selection.adjacentID(offset: -1, in: ["only"]) == "only")
        selection.reconcile(with: [])
        #expect(selection.selectedID == nil)
    }

    @Test func refreshedOrderKeepsTheSelectedTitle() {
        var selection = HeroCarouselSelection()
        selection.select("second", in: ids)
        let refreshed = ["new", "third", "first", "second"]
        selection.reconcile(with: refreshed)
        #expect(selection.selectedID == "second")
        #expect(selection.adjacentID(offset: 1, in: refreshed) == "new")
    }

    @Test func removedSelectionFallsBackWithoutAnInvalidIndex() {
        var selection = HeroCarouselSelection()
        selection.select("third", in: ids)
        #expect(selection.currentID(in: ["replacement"]) == "replacement")
        selection.reconcile(with: ["replacement"])
        #expect(selection.selectedID == "replacement")
        selection.reconcile(with: [])
        selection.reconcile(with: ids)
        #expect(selection.selectedID == "first")
    }

    @Test func transientOrStaleScrollTargetsDoNotResetSelection() {
        var selection = HeroCarouselSelection()
        selection.select("second", in: ids)
        selection.select(nil, in: ids)
        selection.select("removed", in: ids)
        #expect(selection.selectedID == "second")
    }
}

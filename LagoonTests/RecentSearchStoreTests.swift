import Foundation
import Testing
@testable import Lagoon

@Suite("Recent searches")
struct RecentSearchStoreTests {
    /// Each test gets its own defaults domain, so nothing here can read or
    /// write the running app's recents.
    private func makeStore(function: String = #function) -> (RecentSearchStore, UserDefaults) {
        let suite = "RecentSearchStoreTests.\(function)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        return (RecentSearchStore(defaults: defaults), defaults)
    }

    @Test @MainActor func mostRecentComesFirst() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("severance")
        #expect(store.terms == ["severance", "dune"])
    }

    /// Searching the same title again should move it up the row, not add a
    /// second entry beside itself.
    @Test @MainActor func repeatingATermMovesItToTheFrontWithoutDuplicating() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("severance")
        store.record("dune")
        #expect(store.terms == ["dune", "severance"])
    }

    /// The keyboard makes case and stray spaces easy to vary between two
    /// attempts at the same title, and two rows saying "Dune" is noise.
    @Test @MainActor func caseAndPaddingDoNotMakeANewEntry() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("  DUNE ")
        #expect(store.terms == ["DUNE"])
    }

    /// The tvOS keyboard is entered a letter at a time and every prefix runs
    /// as its own search, so the row filled up with the spelling rather than
    /// the title.
    @Test @MainActor func spellingOutATitleLeavesOnlyTheTitle() {
        let (store, _) = makeStore()
        for prefix in ["d", "du", "dun", "dune"] { store.record(prefix) }
        #expect(store.terms == ["dune"])
    }

    /// Folding runs in one direction only. Someone who searched "the matrix"
    /// last week and "the" today meant both, and the older one has to survive.
    @Test @MainActor func aShorterTermDoesNotEvictTheLongerOneBeforeIt() {
        let (store, _) = makeStore()
        store.record("the matrix")
        store.record("the")
        #expect(store.terms == ["the", "the matrix"])
    }

    /// Whatever case the keyboard was left in between two letters, it is the
    /// same spelling run.
    @Test @MainActor func foldingASpellingRunIgnoresCase() {
        let (store, _) = makeStore()
        store.record("DU")
        store.record("dune")
        #expect(store.terms == ["dune"])
    }

    /// Only what a term was typed *through* folds away. A term that merely
    /// appears inside another is a different search.
    @Test @MainActor func aTermInsideAnotherIsNotASpellingRun() {
        let (store, _) = makeStore()
        store.record("une")
        store.record("dune")
        #expect(store.terms == ["dune", "une"])
    }

    /// History polluted by builds before the fold should tidy itself the next
    /// time the title is searched, without anyone clearing it by hand.
    @Test @MainActor func anAlreadyPollutedHistoryFoldsOnTheNextSearch() throws {
        let (_, defaults) = makeStore()
        let stored = ["dun", "du", "d", "severance"]
        defaults.set(try JSONEncoder().encode(stored), forKey: "search.recents")
        let store = RecentSearchStore(defaults: defaults)
        store.record("dune")
        #expect(store.terms == ["dune", "severance"])
    }

    @Test @MainActor func blankTermsAreNotRecorded() {
        let (store, _) = makeStore()
        store.record("")
        store.record("   ")
        store.record("\n")
        #expect(store.terms.isEmpty)
    }

    @Test @MainActor func theRowStopsAtTheLimit() {
        let (store, _) = makeStore()
        for index in 0..<(RecentSearchStore.limit + 5) {
            store.record("term \(index)")
        }
        #expect(store.terms.count == RecentSearchStore.limit)
        // The oldest fell off the end, not the newest.
        #expect(store.terms.first == "term \(RecentSearchStore.limit + 4)")
        #expect(!store.terms.contains("term 0"))
    }

    @Test @MainActor func recentsSurviveARelaunch() {
        let (store, defaults) = makeStore()
        store.record("dune")
        store.record("severance")
        let reopened = RecentSearchStore(defaults: defaults)
        #expect(reopened.terms == ["severance", "dune"])
    }

    /// Account switching calls this, so it has to reach the disk and not
    /// only the in-memory copy.
    @Test @MainActor func clearingEmptiesTheStoredHistoryToo() {
        let (store, defaults) = makeStore()
        store.record("dune")
        store.clear()
        #expect(store.terms.isEmpty)
        #expect(RecentSearchStore(defaults: defaults).terms.isEmpty)
    }

    /// A defaults value written by a future build with a bigger limit must
    /// not make this build render an over-long row.
    @Test @MainActor func anOverlongStoredListIsTrimmedOnLoad() throws {
        let (_, defaults) = makeStore()
        let stored = (0..<(RecentSearchStore.limit + 8)).map { "term \($0)" }
        defaults.set(try JSONEncoder().encode(stored), forKey: "search.recents")
        #expect(RecentSearchStore(defaults: defaults).terms.count == RecentSearchStore.limit)
    }
}

import Foundation
import Testing
@testable import Lagoon

@Suite("Recent searches")
struct RecentSearchStoreTests {
    /// A defaults domain per test, apart from the running app's recents.
    private func makeStore(function: String = #function) -> (RecentSearchStore, UserDefaults) {
        let suite = "RecentSearchStoreTests.\(function)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        let defaults = UserDefaults(suiteName: suite)!
        let store = RecentSearchStore(defaults: defaults)
        store.configure(accountID: "viewer-a")
        return (store, defaults)
    }

    @Test @MainActor func mostRecentComesFirst() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("severance")
        #expect(store.terms == ["severance", "dune"])
    }

    @Test @MainActor func repeatingATermMovesItToTheFrontWithoutDuplicating() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("severance")
        store.record("dune")
        #expect(store.terms == ["dune", "severance"])
    }

    @Test @MainActor func caseAndPaddingDoNotMakeANewEntry() {
        let (store, _) = makeStore()
        store.record("dune")
        store.record("  DUNE ")
        #expect(store.terms == ["DUNE"])
    }

    /// On tvOS every typed prefix runs as its own search.
    @Test @MainActor func spellingOutATitleLeavesOnlyTheTitle() {
        let (store, _) = makeStore()
        for prefix in ["d", "du", "dun", "dune"] { store.record(prefix) }
        #expect(store.terms == ["dune"])
    }

    /// Folding runs one way only: "the" today keeps last week's "the matrix".
    @Test @MainActor func aShorterTermDoesNotEvictTheLongerOneBeforeIt() {
        let (store, _) = makeStore()
        store.record("the matrix")
        store.record("the")
        #expect(store.terms == ["the", "the matrix"])
    }

    @Test @MainActor func foldingASpellingRunIgnoresCase() {
        let (store, _) = makeStore()
        store.record("DU")
        store.record("dune")
        #expect(store.terms == ["dune"])
    }

    /// Only a term typed *through* folds away, not one found inside another.
    @Test @MainActor func aTermInsideAnotherIsNotASpellingRun() {
        let (store, _) = makeStore()
        store.record("une")
        store.record("dune")
        #expect(store.terms == ["dune", "une"])
    }

    @Test @MainActor func anAlreadyPollutedHistoryFoldsOnTheNextSearch() throws {
        let (_, defaults) = makeStore()
        let stored = ["dun", "du", "d", "severance"]
        defaults.set(try JSONEncoder().encode(stored), forKey: "search.recents.viewer-a")
        let store = RecentSearchStore(defaults: defaults)
        store.configure(accountID: "viewer-a")
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
        reopened.configure(accountID: "viewer-a")
        #expect(reopened.terms == ["severance", "dune"])
    }

    /// Account switching calls this, so it must reach the disk.
    @Test @MainActor func clearingEmptiesTheStoredHistoryToo() {
        let (store, defaults) = makeStore()
        store.record("dune")
        store.clear()
        #expect(store.terms.isEmpty)
        let reopened = RecentSearchStore(defaults: defaults)
        reopened.configure(accountID: "viewer-a")
        #expect(reopened.terms.isEmpty)
    }

    /// A future build may store more than this build's limit.
    @Test @MainActor func anOverlongStoredListIsTrimmedOnLoad() throws {
        let (_, defaults) = makeStore()
        let stored = (0..<(RecentSearchStore.limit + 8)).map { "term \($0)" }
        defaults.set(try JSONEncoder().encode(stored), forKey: "search.recents.viewer-a")
        let reopened = RecentSearchStore(defaults: defaults)
        reopened.configure(accountID: "viewer-a")
        #expect(reopened.terms.count == RecentSearchStore.limit)
    }
}

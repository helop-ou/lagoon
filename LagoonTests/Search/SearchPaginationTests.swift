import Foundation
import Testing
@testable import Lagoon

@Suite("Search pagination")
@MainActor
struct SearchPaginationTests {
    private func item(_ id: String) throws -> SearchResultItem {
        .library(try JellyfinClient.decoder.decode(MediaItem.self,
            from: Data("{\"Id\":\"\(id)\",\"Type\":\"Movie\"}".utf8)))
    }

    @Test func rawLibraryOffsetsSurviveFiltering() throws {
        let response = try JellyfinClient.decoder.decode(ItemsPage.self, from: Data(#"{"Items":[{"Id":"empty","Type":"BoxSet","ChildCount":0},{"Id":"movie","Type":"Movie"}],"TotalRecordCount":3}"#.utf8))
        let page = SearchResultsPage.library(response, offset: 0, limit: 2)
        #expect(page.items.map(\.id) == ["library:movie"])
        #expect(page.nextOffset == 2)
        #expect(SearchResultsPage.library(response, offset: 2, limit: 2).nextOffset == nil)
    }

    @Test func filteredSeerrPagesStillOfferTheNextPage() throws {
        let response = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(#"{"page":1,"totalPages":2,"totalResults":21,"results":[{"id":1,"mediaType":"person","name":"Person"}]}"#.utf8))
        let page = SearchResultsPage.seerr(response)
        #expect(page.items.isEmpty)
        #expect(page.nextOffset == 1)
    }

    @Test func movieAndShowWithTheSameTMDBNumberAreDistinct() throws {
        let response = try JSONDecoder().decode(SeerrDiscoverPage.self, from: Data(#"{"page":1,"totalPages":1,"totalResults":2,"results":[{"id":1,"mediaType":"movie","title":"Movie"},{"id":1,"mediaType":"tv","name":"Show"}]}"#.utf8))
        let page = SearchResultsPage.seerr(response)
        #expect(Set(page.items.map(\.id)).count == 2)
        #expect(page.nextOffset == nil)
    }

    @Test func deduplicatesPagesAndStopsAtTheEnd() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a"), second = try item("b")
        await model.loadNext { offset in
            #expect(offset == 0)
            return SearchResultsPage(items: [first, first], nextOffset: 2)
        }
        await model.loadNext { offset in
            #expect(offset == 2)
            return SearchResultsPage(items: [first, second], nextOffset: nil)
        }
        await model.loadNext { _ in
            Issue.record("Requested another page after the end")
            return SearchResultsPage(items: [], nextOffset: nil)
        }
        #expect(model.items.map(\.id) == ["library:a", "library:b"])
        #expect(!model.isLoading)
    }

    @Test func failuresPreserveTheCursorAndLoadedResultsForRetry() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a")
        await model.loadNext { _ in SearchResultsPage(items: [first], nextOffset: 1) }
        await model.loadNext { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.items.count == 1)
        #expect(model.nextOffset == 1)
        #expect(model.errorMessage != nil)
        await model.loadNext { offset in
            #expect(offset == 1)
            return SearchResultsPage(items: [], nextOffset: nil)
        }
        #expect(model.errorMessage == nil)
    }

    /// A spent cursor makes `loadNext` a no-op, so retry must rewind it.
    @Test func retryingAnEmptyPageRewindsTheCursorAndSearchesAgain() async throws {
        let model = SearchResultsViewModel()
        await model.loadNext { _ in SearchResultsPage(items: [], nextOffset: nil) }
        #expect(model.items.isEmpty)
        #expect(model.nextOffset == nil)

        model.restart()
        #expect(model.nextOffset == 0)
        let found = try item("a")
        await model.loadNext { offset in
            #expect(offset == 0)
            return SearchResultsPage(items: [found], nextOffset: nil)
        }
        #expect(model.items.map(\.id) == ["library:a"])
    }

    @Test func cancellationDoesNotApplyLateResults() async throws {
        let model = SearchResultsViewModel()
        let first = try item("a")
        let task = Task {
            await model.loadNext { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return SearchResultsPage(items: [first], nextOffset: 1)
            }
        }
        await task.value
        #expect(model.items.isEmpty)
        #expect(model.nextOffset == 0)
        #expect(!model.isLoading)
    }
}

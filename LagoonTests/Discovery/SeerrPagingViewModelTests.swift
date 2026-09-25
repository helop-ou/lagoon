import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr paging")
@MainActor
struct SeerrPagingViewModelTests {
    private struct Item: Identifiable, Equatable {
        let id: Int
    }

    @Test func pagesAndAResetRetainTheLoadedDepth() async {
        let model = SeerrPagingViewModel<Item>()
        var requestedPages: [Int] = []
        let fetch: (Int) async throws -> SeerrPage<Item> = { page in
            requestedPages.append(page)
            return SeerrPage(items: [Item(id: page)], page: page, totalPages: 3)
        }
        await model.load(fetch: fetch)
        await model.load(fetch: fetch)
        #expect(model.items.map(\.id) == [1, 2])
        await model.load(reset: true, fetch: fetch)
        #expect(model.items.map(\.id) == [1])
        #expect(requestedPages == [1, 2, 1])
    }

    @Test func duplicatesDoNotBreakPagingAndTheLastPageStopsIt() async {
        let model = SeerrPagingViewModel<Item>()
        await model.load { _ in SeerrPage(items: [Item(id: 1), Item(id: 2)], page: 1, totalPages: 2) }
        #expect(model.items.map(\.id) == [1, 2])
        await model.load { _ in SeerrPage(items: [Item(id: 2), Item(id: 3)], page: 2, totalPages: 2) }
        #expect(model.items.map(\.id) == [1, 2, 3])
        var calledAgain = false
        await model.load { _ in
            calledAgain = true
            return SeerrPage(items: [], page: 2, totalPages: 2)
        }
        #expect(!calledAgain, "page == totalPages must stop paging without another fetch")
    }

    @Test func aStalePageCannotOverwriteANewerReset() async {
        let model = SeerrPagingViewModel<Item>()
        await model.load { _ in SeerrPage(items: [Item(id: 1)], page: 1, totalPages: 5) }
        var pending: CheckedContinuation<SeerrPage<Item>, Error>?
        let oldRequest = Task {
            await model.load { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(reset: true) { _ in SeerrPage(items: [Item(id: 9)], page: 1, totalPages: 1) }
        pending?.resume(returning: SeerrPage(items: [Item(id: 2)], page: 2, totalPages: 5))
        await oldRequest.value
        #expect(model.items.map(\.id) == [9])
        #expect(!model.isLoading)
    }

    /// The generation guard covers the failure branch too, not just success:
    /// a page that resolves after a newer reset must not report its error.
    @Test func aStaleFailureCannotOverwriteANewerResetsSuccess() async {
        let model = SeerrPagingViewModel<Item>()
        var pending: CheckedContinuation<SeerrPage<Item>, Error>?
        let oldRequest = Task {
            await model.load { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(reset: true) { _ in SeerrPage(items: [Item(id: 1)], page: 1, totalPages: 1) }
        pending?.resume(throwing: URLError(.notConnectedToInternet))
        await oldRequest.value
        #expect(model.errorMessage == nil)
        #expect(model.items.map(\.id) == [1])
    }

    /// A reset always takes effect, even mid-load: it must not silently
    /// no-op just because a page is already in flight.
    @Test func aResetTakesEffectEvenWhileALoadIsInFlight() async {
        let model = SeerrPagingViewModel<Item>()
        var pending: CheckedContinuation<SeerrPage<Item>, Error>?
        let inFlight = Task {
            await model.load { _ in
                try await withCheckedThrowingContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        #expect(model.isLoading)
        await model.load(reset: true) { _ in SeerrPage(items: [Item(id: 7)], page: 1, totalPages: 1) }
        #expect(model.items.map(\.id) == [7])
        pending?.resume(returning: SeerrPage(items: [Item(id: 99)], page: 1, totalPages: 1))
        await inFlight.value
        #expect(model.items.map(\.id) == [7])
    }

    @Test func aFailedLoadCanBeRetried() async {
        let model = SeerrPagingViewModel<Item>()
        await model.load { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.errorMessage != nil)
        #expect(model.items.isEmpty)
        await model.load { _ in SeerrPage(items: [Item(id: 1)], page: 1, totalPages: 1) }
        #expect(model.items.map(\.id) == [1])
        #expect(model.errorMessage == nil)
    }
}

import Foundation
import Testing
@testable import Lagoon

@Suite("Library browsing", .serialized)
@MainActor
struct LibraryBrowseTests {
    @Test func selectionsAreRememberedPerAccountAndInvalidDataFallsBack() {
        let name = "LibraryBrowseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var selection = LibrarySelection(kind: .movies, sort: .rating)
        selection.genre = "Science Fiction"
        selection.decade = LibraryDecade(rawValue: 2000)
        selection.favoritesOnly = true
        selection.save(accountID: "server|alice", defaults: defaults)
        #expect(LibrarySelection.restore(accountID: "server|alice", defaults: defaults) == selection)
        #expect(LibrarySelection.restore(accountID: "server|bob", defaults: defaults) == LibrarySelection())
        defaults.set(Data("invalid".utf8), forKey: "library.selection.server|alice")
        #expect(LibrarySelection.restore(accountID: "server|alice", defaults: defaults) == LibrarySelection())
    }

    @Test func decadesHaveExactBoundariesAndOnlyIncludeYearsInTheLibrary() throws {
        let decade = try #require(LibraryDecade(rawValue: 2000))
        #expect(decade.title == "2000–2009")
        #expect(decade.years == Array(2000...2009))
        #expect(!decade.years.contains(2010))
        #expect(LibraryDecade(rawValue: 2001) == nil)
        #expect(LibraryDecade(rawValue: Int.max) == nil)
        #expect(LibraryDecade.choices(years: [2009, 1992, 2000, 1992, 2031, 1878]).map(\.rawValue) == [2030, 2000, 1990, 1870])
        #expect(LibraryDecade.choices(years: []).isEmpty)
        #expect(LibraryDecade.choices(years: [0, -1, Int.min, 10_000, Int.max]).isEmpty)
        #expect(String(decoding: try JSONEncoder().encode(decade), as: UTF8.self) == "2000")
    }

    @Test func yearScopeIgnoresOtherFiltersAndMissingSavedDecadesClearOnlyOnReconciliation() {
        var selection = LibrarySelection(kind: .movies, libraryID: "cinema", genre: "Horror", decade: LibraryDecade(rawValue: 2000), unwatchedOnly: true)
        #expect(selection.yearScope == LibrarySelection(kind: .movies, libraryID: "cinema").yearScope)
        #expect(selection.yearScope != LibrarySelection(kind: .shows, libraryID: "cinema").yearScope)
        #expect(selection.yearScope != LibrarySelection(kind: .movies, libraryID: "kids").yearScope)
        selection.reconcileDecade(available: LibraryDecade.choices(years: [2008]))
        #expect(selection.decade?.rawValue == 2000)
        selection.reconcileDecade(available: LibraryDecade.choices(years: [2012]))
        #expect(selection.decade == nil)
        #expect(selection.genre == "Horror")
        #expect(selection.unwatchedOnly)
    }

    @Test func decadeCatalogueRefreshesAndRetainsOnlyTheSameScopesLastGoodList() async throws {
        let model = LibraryDecadeViewModel()
        let movies = LibraryYearScope(kind: .movies, libraryID: "cinema")
        await model.load(scope: movies) { scope in
            #expect(scope == movies)
            return [1999, 2001, 2009]
        }
        #expect(model.decades?.map(\.rawValue) == [2000, 1990])
        await model.load(scope: movies) { _ in [2001, 2021] }
        #expect(model.decades?.map(\.rawValue) == [2020, 2000])
        await model.load(scope: movies) { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.loadFailed)
        #expect(model.decades?.map(\.rawValue) == [2020, 2000])

        let kids = LibraryYearScope(kind: .movies, libraryID: "kids")
        let saved = LibraryDecade(rawValue: 1990)
        #expect(model.choices(for: kids, selected: saved).map(\.rawValue) == [1990])
        await model.load(scope: kids) { _ in throw URLError(.notConnectedToInternet) }
        #expect(model.decades == nil)
        #expect(model.loadFailed)
        #expect(model.choices(for: kids, selected: saved).map(\.rawValue) == [1990])
        await model.load(scope: kids) { _ in [] }
        #expect(model.decades == [])
        #expect(!model.loadFailed)
    }

    @Test func anOldYearCatalogueCannotOverwriteANewerMediaType() async throws {
        let model = LibraryDecadeViewModel()
        let movies = LibraryYearScope(kind: .movies, libraryID: nil)
        let shows = LibraryYearScope(kind: .shows, libraryID: nil)
        var pending: CheckedContinuation<[Int], Never>?
        let oldRequest = Task {
            await model.load(scope: movies) { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(scope: shows) { _ in [2015] }
        pending?.resume(returning: [1980])
        await oldRequest.value
        #expect(model.scope == shows)
        #expect(model.decades?.map(\.rawValue) == [2010])
        #expect(!model.isLoading)
        #expect(!model.loadFailed)
    }

    @Test func aCancelledYearRequestDoesNotPublishOrEraseASavedSelection() async throws {
        let model = LibraryDecadeViewModel()
        let scope = LibraryYearScope(kind: .all, libraryID: nil)
        var pending: CheckedContinuation<[Int], Never>?
        let request = Task {
            await model.load(scope: scope) { _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        request.cancel()
        pending?.resume(returning: [])
        await request.value
        #expect(model.decades == nil)
        #expect(!model.isLoading)
        #expect(model.choices(for: scope, selected: LibraryDecade(rawValue: 2000)).map(\.rawValue) == [2000])
    }

    @Test func catalogueYearsAreUserScopedAndUnboundedByPagingOrCurrentFilters() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryQueryURLProtocol.self]
        let client = JellyfinClient(deviceId: "library-tests", sessionConfiguration: config)
        client.configure(serverURL: URL(string: "https://library.test")!)
        client.activateSession(token: "token", userId: "user")
        for kind in LibraryMediaKind.allCases {
            for libraryID: String? in [nil, "cinema"] {
                let years = try await client.libraryYears(LibraryYearScope(kind: kind, libraryID: libraryID))
                #expect(years == [1978, 2001, 2009, 2001, 2032])
                let url = try #require(LibraryQueryURLProtocol.lastURL)
                #expect(url.path == "/Items/Filters")
                let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
                var expected = ["UserId": "user", "IncludeItemTypes": kind.includeTypes.map(\.rawValue).joined(separator: ",")]
                expected["ParentId"] = libraryID
                #expect(query == expected)
            }
        }
        for json in [#"{}"#, #"{"years":null}"#] {
            #expect(try JSONDecoder().decode(LibraryYearFilters.self, from: Data(json.utf8)).years.isEmpty)
        }
    }

    @Test func preferencesSavedBeforeDecadeFilteringStillRestore() throws {
        let name = "LibraryBrowseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let oldData = Data(#"{"kind":"movies","sort":"rating","genre":"Horror","unwatchedOnly":true,"favoritesOnly":false,"only4K":true}"#.utf8)
        defaults.set(oldData, forKey: "library.selection.old-account")
        let selection = LibrarySelection.restore(accountID: "old-account", defaults: defaults)
        #expect(selection == LibrarySelection(kind: .movies, sort: .rating, genre: "Horror", unwatchedOnly: true, only4K: true))
        #expect(selection.decade == nil)
    }

    @Test func decadeCountsAsOneFilterAndClearsWithoutResettingMediaTypeOrSort() {
        var selection = LibrarySelection(kind: .movies, sort: .rating, genre: "Horror", decade: LibraryDecade(rawValue: 2000), unwatchedOnly: true)
        #expect(selection.filterCount == 3)
        selection.selectKind(.shows, libraries: [])
        #expect(selection.decade?.rawValue == 2000)
        selection.clearFilters()
        #expect(selection.decade == nil)
        #expect(selection.filterCount == 0)
        #expect(selection.kind == .shows)
        #expect(selection.sort == .rating)
    }

    @Test func changingMediaTypeDropsIncompatibleSourceAndFileResolutionFilter() throws {
        let libraries = try JSONDecoder().decode([LibraryTab].self, from: Data(#"[{"id":"movies","name":"Cinema","collectionType":"movies"},{"id":"shows","name":"TV","collectionType":"tvshows"}]"#.utf8))
        var selection = LibrarySelection(kind: .movies, libraryID: "movies", genre: "Drama", only4K: true)
        selection.selectKind(.shows, libraries: libraries)
        #expect(selection.libraryID == nil)
        #expect(!selection.only4K)
        #expect(selection.genre == "Drama")
        selection.libraryID = "removed-library"
        selection.reconcile(libraries: libraries)
        #expect(selection.libraryID == nil)
    }

    @Test func pagesAndRefreshRetainTheWholeQueryAndLoadedDepth() async throws {
        let model = LibraryViewModel()
        let selection = LibrarySelection(kind: .movies, sort: .recentlyAdded, genre: "Drama", decade: LibraryDecade(rawValue: 2000), unwatchedOnly: true)
        var requests: [(LibrarySelection, Int, Int)] = []
        let fetch: LibraryViewModel.FetchPage = { query, start, limit in
            requests.append((query, start, limit))
            return try page(ids: (start..<(start + limit)).map(String.init), total: 180)
        }
        await model.load(selection: selection, fetch: fetch)
        await model.loadMore(fetch: fetch)
        #expect(model.items.count == 120)
        await model.refresh(fetch: fetch)
        #expect(model.items.count == 120)
        #expect(requests.map { $0.0 } == [selection, selection, selection])
        #expect(requests.map { $0.1 } == [0, 60, 0])
        #expect(requests.map { $0.2 } == [60, 60, 120])
    }

    @Test func changingOnlyTheDecadeResetsPaginationAndRetainsOtherFilters() async throws {
        let model = LibraryViewModel()
        var selection = LibrarySelection(kind: .movies, sort: .rating, genre: "Horror", decade: LibraryDecade(rawValue: 1990), unwatchedOnly: true)
        await model.load(selection: selection) { _, _, _ in
            try page(ids: ["old-decade"], total: 2)
        }
        await model.loadMore { _, start, _ in
            #expect(start == 1)
            return try page(ids: ["old-decade-page-two"], total: 2)
        }
        selection.decade = LibraryDecade(rawValue: 2000)
        let expected = selection
        await model.load(selection: selection) { query, start, _ in
            #expect(query == expected)
            #expect(start == 0)
            return try page(ids: ["new-decade"], total: 1)
        }
        #expect(model.items.map(\.id) == ["new-decade"])
        #expect(model.totalCount == 1)
        #expect(!model.hasMore)
    }

    @Test func redundantSavedLibraryBecomesItsMediaTypeWhileDistinctLibrariesStaySelectable() throws {
        let libraries = try JSONDecoder().decode([LibraryTab].self, from: Data(#"[{"id":"movies","name":"Movies","collectionType":"movies"},{"id":"shows","name":"Shows","collectionType":"tvshows"}]"#.utf8))
        #expect(LibraryMediaKind.all.libraryChoices(in: libraries).isEmpty)
        #expect(LibraryMediaKind.movies.libraryChoices(in: libraries).isEmpty)

        var saved = LibrarySelection(libraryID: "movies", genre: "Drama", favoritesOnly: true)
        saved.reconcile(libraries: libraries)
        #expect(saved.kind == .movies)
        #expect(saved.libraryID == nil)
        #expect(saved.genre == "Drama")
        #expect(saved.favoritesOnly)

        let kids = try JSONDecoder().decode(LibraryTab.self, from: Data(#"{"id":"kids","name":"Kids' Movies","collectionType":"movies"}"#.utf8))
        let expanded = libraries + [kids]
        #expect(LibraryMediaKind.movies.libraryChoices(in: expanded).map(\.id) == ["movies", "kids"])
        #expect(LibraryMediaKind.all.libraryChoices(in: expanded).count == 3)
        #expect(LibraryMediaKind.shows.libraryChoices(in: expanded).isEmpty)
        saved.libraryID = "kids"
        saved.reconcile(libraries: expanded)
        #expect(saved.libraryID == "kids")
        saved.selectKind(.shows, libraries: expanded)
        #expect(saved.libraryID == nil)
    }

    @Test func anOldPageCannotOverwriteANewerFilterSelection() async throws {
        let model = LibraryViewModel()
        await model.load(selection: LibrarySelection(kind: .movies)) { _, _, _ in
            try page(ids: ["movie"], total: 2)
        }
        var pending: CheckedContinuation<ItemsPage, Never>?
        let oldRequest = Task {
            await model.loadMore { _, _, _ in
                await withCheckedContinuation { pending = $0 }
            }
        }
        while pending == nil { await Task.yield() }
        await model.load(selection: LibrarySelection(kind: .shows)) { _, start, _ in
            #expect(start == 0)
            return try page(ids: ["show"], total: 1)
        }
        pending?.resume(returning: try page(ids: ["stale-movie"], total: 2))
        await oldRequest.value
        #expect(model.items.map(\.id) == ["show"])
        #expect(model.totalCount == 1)
        #expect(!model.isLoading)
        #expect(!model.hasMore)
    }

    @Test func duplicatesDoNotBreakOffsetsAndAnEmptyPageStopsPagination() async throws {
        let model = LibraryViewModel()
        await model.load(selection: LibrarySelection()) { _, _, _ in
            try page(ids: ["a", "b"], total: 10)
        }
        await model.loadMore { _, start, _ in
            #expect(start == 2)
            return try page(ids: ["b", "c"], total: 10)
        }
        #expect(model.items.map(\.id) == ["a", "b", "c"])
        await model.loadMore { _, start, _ in
            #expect(start == 4)
            return try page(ids: [], total: 10)
        }
        #expect(!model.hasMore)
    }

    @Test func failedRefreshKeepsContentAndFailedNextPageCanBeRetried() async throws {
        let model = LibraryViewModel()
        await model.load(selection: LibrarySelection()) { _, _, _ in
            try page(ids: ["a"], total: 2)
        }
        await model.refresh { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(model.items.map(\.id) == ["a"])
        #expect(model.errorMessage == nil)
        await model.loadMore { _, _, _ in throw URLError(.notConnectedToInternet) }
        #expect(model.errorMessage != nil)
        await model.loadMore { _, start, _ in
            #expect(start == 1)
            return try page(ids: ["b"], total: 2)
        }
        #expect(model.items.map(\.id) == ["a", "b"])
        #expect(model.errorMessage == nil)
        #expect(!model.hasMore)
    }

    @Test func libraryQueryReachesJellyfinWithCombinedFiltersAndPaging() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryQueryURLProtocol.self]
        let client = JellyfinClient(deviceId: "library-tests", sessionConfiguration: config)
        client.configure(serverURL: URL(string: "https://library.test")!)
        client.activateSession(token: "token", userId: "user")
        let selection = LibrarySelection(
            kind: .movies, sort: .rating, libraryID: "cinema", genre: "Science Fiction", decade: LibraryDecade(rawValue: 2000),
            unwatchedOnly: true, favoritesOnly: true, only4K: true
        )
        _ = try await client.libraryItems(selection, startIndex: 60, limit: 60)
        let url = try #require(LibraryQueryURLProtocol.lastURL)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(url.path == "/Users/user/Items")
        #expect(query["ParentId"] == "cinema")
        #expect(query["IncludeItemTypes"] == "Movie")
        #expect(query["SortBy"] == "CommunityRating,SortName")
        #expect(query["SortOrder"] == "Descending,Ascending")
        #expect(query["Genres"] == "Science Fiction")
        #expect(query["Years"] == "2000,2001,2002,2003,2004,2005,2006,2007,2008,2009")
        #expect(query["Filters"] == "IsUnplayed,IsFavorite")
        #expect(query["Is4K"] == "true")
        #expect(query["StartIndex"] == "60")
        #expect(query["Limit"] == "60")
    }

    @Test func decadeQueryWorksForEveryMediaTypeAndAllDecadesOmitsYears() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LibraryQueryURLProtocol.self]
        let client = JellyfinClient(deviceId: "library-tests", sessionConfiguration: config)
        client.configure(serverURL: URL(string: "https://library.test")!)
        client.activateSession(token: "token", userId: "user")
        for kind in LibraryMediaKind.allCases {
            var selection = LibrarySelection(kind: kind, genre: "Drama", decade: LibraryDecade(rawValue: 2010))
            _ = try await client.libraryItems(selection, startIndex: 0, limit: 60)
            let url = try #require(LibraryQueryURLProtocol.lastURL)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(query.first { $0.name == "Years" }?.value == "2010,2011,2012,2013,2014,2015,2016,2017,2018,2019")
            #expect(query.first { $0.name == "IncludeItemTypes" }?.value == kind.includeTypes.map(\.rawValue).joined(separator: ","))
            selection.decade = nil
            _ = try await client.libraryItems(selection, startIndex: 0, limit: 60)
            let unfilteredURL = try #require(LibraryQueryURLProtocol.lastURL)
            let unfiltered = URLComponents(url: unfilteredURL, resolvingAgainstBaseURL: false)!.queryItems!
            #expect(!unfiltered.contains { $0.name == "Years" })
            #expect(unfiltered.first { $0.name == "Genres" }?.value == "Drama")
        }
    }

    private func page(ids: [String], total: Int) throws -> ItemsPage {
        let data = try JSONSerialization.data(withJSONObject: [
            "items": ids.map { ["id": $0, "name": $0, "type": "Movie"] },
            "totalRecordCount": total,
        ])
        return try JSONDecoder().decode(ItemsPage.self, from: data)
    }
}

private nonisolated final class LibraryQueryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recordedURL: URL?
    static var lastURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return recordedURL
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "library.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.recordedURL = url
        Self.lock.unlock()
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = url.path == "/Items/Filters"
            ? #"{"Years":[1978,2001,2009,2001,2032]}"#
            : #"{"Items":[],"TotalRecordCount":0}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

import Foundation
import Observation

@Observable
final class LibraryViewModel {
    typealias FetchPage = @MainActor (LibrarySelection, Int, Int) async throws -> ItemsPage

    private(set) var items: [MediaItem] = []
    private(set) var totalCount: Int?
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var hasMore = true
    private(set) var errorMessage: String?
    private var selection: LibrarySelection?
    private var revision = 0
    private var nextStartIndex = 0
    private let pageSize = 60

    func load(selection: LibrarySelection, fetch: FetchPage) async {
        guard self.selection != selection || !hasLoaded else { return }
        revision &+= 1
        self.selection = selection
        items = []
        totalCount = nil
        nextStartIndex = 0
        hasMore = true
        hasLoaded = false
        isLoading = false
        errorMessage = nil
        await loadMore(fetch: fetch)
    }

    func loadMore(fetch: FetchPage) async {
        guard let selection, !isLoading, hasMore else { return }
        let revision = revision
        isLoading = true
        errorMessage = nil
        defer { if self.revision == revision { isLoading = false } }
        do {
            let page = try await fetch(selection, nextStartIndex, pageSize)
            guard self.revision == revision, !Task.isCancelled else { return }
            var seen = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { seen.insert($0.id).inserted })
            // Offsets count server rows, including duplicates from a library
            // changing between requests, rather than the deduplicated grid.
            nextStartIndex += page.items.count
            totalCount = page.totalRecordCount
            hasMore = !page.items.isEmpty && (totalCount.map { nextStartIndex < $0 } ?? true)
            hasLoaded = true
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            errorMessage = String(localized: "Couldn't load this library.")
        }
    }

    func refresh(fetch: FetchPage) async {
        guard let selection, hasLoaded, !isLoading else { return }
        let revision = revision
        isLoading = true
        defer { if self.revision == revision { isLoading = false } }
        do {
            let page = try await fetch(selection, 0, max(pageSize, nextStartIndex))
            guard self.revision == revision, !Task.isCancelled else { return }
            var seen = Set<String>()
            items = page.items.filter { seen.insert($0.id).inserted }
            nextStartIndex = page.items.count
            totalCount = page.totalRecordCount
            hasMore = !page.items.isEmpty && (totalCount.map { nextStartIndex < $0 } ?? true)
            errorMessage = nil
        } catch {
            // A foreground refresh must retain the last usable grid.
        }
    }
}

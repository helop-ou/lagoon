import Foundation
import Observation

/// One page of a Seerr paginated endpoint, generalized over the item type
/// so `SeerrPagingViewModel` can drive both discovery catalogs and request
/// lists from the same paging machine.
struct SeerrPage<Item> {
    let items: [Item]
    let page: Int
    let totalPages: Int
}

/// Seerr's `page`/`totalPages` paging, shared by any screen that walks one
/// of its endpoints. A `reset` always takes effect, even mid-load, and its
/// generation guard drops an older fetch that resolves after a newer reset
/// has already started.
@Observable
final class SeerrPagingViewModel<Item: Identifiable> {
    private(set) var items: [Item] = []
    private(set) var isLoading = false
    var errorMessage: String?
    private var page = 0
    private var totalPages = 1
    private var generation = 0

    func load(reset: Bool = false, fetch: (Int) async throws -> SeerrPage<Item>) async {
        if reset {
            // Supersedes an older request still unwinding after cancellation.
            generation += 1
            items = []
            page = 0
            totalPages = 1
        } else {
            guard !isLoading else { return }
        }
        guard page < totalPages else { return }
        let generation = generation
        isLoading = true
        defer { if self.generation == generation { isLoading = false } }
        errorMessage = nil
        do {
            let result = try await fetch(page + 1)
            guard !Task.isCancelled, self.generation == generation else { return }
            let existing = Set(items.map(\.id))
            items += result.items.filter { !existing.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
        } catch is CancellationError {
        } catch {
            guard self.generation == generation else { return }
            errorMessage = error.localizedDescription
        }
    }
}

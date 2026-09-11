import Foundation
import Observation

@Observable
final class SeerrRequestsViewModel {
    var requests: [SeerrMediaRequest] = []
    var page = 0
    var totalPages = 1
    var isLoading = false
    var errorMessage: String?
    private var loadGeneration = 0

    func load(
        client: SeerrClient,
        user: SeerrUser,
        filter: SeerrRequestFilter,
        onlyMine: Bool,
        reset: Bool = false
    ) async {
        if reset {
            // A filter/scope change owns a new generation. Let it supersede
            // an older request whose task is still unwinding after SwiftUI
            // cancelled it.
            loadGeneration += 1
            requests = []
            page = 0
            totalPages = 1
        } else {
            guard !isLoading else { return }
        }
        guard page < totalPages else { return }
        let generation = loadGeneration
        isLoading = true
        defer {
            if loadGeneration == generation {
                isLoading = false
            }
        }
        errorMessage = nil
        do {
            let result = try await client.requests(
                take: 20,
                skip: page * 20,
                filter: filter,
                requestedBy: onlyMine ? user.id : nil
            )
            guard !Task.isCancelled, loadGeneration == generation else { return }
            let existing = Set(requests.map(\.id))
            requests += result.results.filter { !existing.contains($0.id) }
            page = result.pageInfo.page
            totalPages = result.pageInfo.pages
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

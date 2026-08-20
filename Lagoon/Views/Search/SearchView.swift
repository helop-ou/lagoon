import Foundation
import Observation

@Observable
final class SearchViewModel {
    var results: [MediaItem] = []
    var isSearching = false
    var errorMessage: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(_ query: String, client: JellyfinClient) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                let page = try await client.items(
                    includeTypes: [.movie, .series],
                    searchTerm: trimmed,
                    limit: 60
                )
                try Task.checkCancellation()
                results = page.items
                isSearching = false
            } catch is CancellationError {
                // A newer query owns all visible state.
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                isSearching = false
                errorMessage = "Couldn't search your library."
            }
        }
    }
}

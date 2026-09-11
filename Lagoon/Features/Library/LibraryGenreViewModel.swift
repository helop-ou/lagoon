import Foundation
import Observation

@Observable
final class LibraryGenreViewModel {
    typealias FetchGenres = @MainActor () async throws -> [MediaGenre]

    /// nil means no successful response yet; [] means an empty catalogue.
    private(set) var genres: [MediaGenre]?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var revision = 0

    func load(fetch: FetchGenres) async {
        guard !Task.isCancelled else { return }
        revision &+= 1
        let revision = revision
        isLoading = true
        loadFailed = false
        defer { if self.revision == revision { isLoading = false } }
        do {
            let genres = try await fetch()
            guard self.revision == revision, !Task.isCancelled else { return }
            self.genres = genres
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            // Refresh failures keep the last good catalogue and saved choice.
            loadFailed = true
        }
    }

    func choices(selected: String?) -> [String] {
        Set((genres ?? []).map(\.name) + [selected].compactMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

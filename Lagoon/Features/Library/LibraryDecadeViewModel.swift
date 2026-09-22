import Foundation
import Observation

@Observable
final class LibraryDecadeViewModel {
    typealias FetchYears = @MainActor (LibraryYearScope) async throws -> [Int]

    private(set) var scope: LibraryYearScope?
    /// nil means no successful response yet; [] means no dated titles.
    private(set) var decades: [LibraryDecade]?
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var revision = 0

    func load(scope: LibraryYearScope, fetch: FetchYears) async {
        // A cancelled task may still be unwinding when its replacement starts;
        // supersede it even for the same scope rather than skip on isLoading.
        guard !Task.isCancelled else { return }
        revision &+= 1
        let revision = revision
        if self.scope != scope { decades = nil }
        self.scope = scope
        isLoading = true
        loadFailed = false
        defer { if self.revision == revision { isLoading = false } }
        do {
            let years = try await fetch(scope)
            guard self.revision == revision, !Task.isCancelled else { return }
            decades = LibraryDecade.choices(years: years)
        } catch {
            guard self.revision == revision, !Task.isCancelled else { return }
            // Keep this scope's last good list; never another library's years.
            loadFailed = true
        }
    }

    func choices(for scope: LibraryYearScope, selected: LibraryDecade?) -> [LibraryDecade] {
        let available = self.scope == scope ? decades ?? [] : []
        // Keep a saved selection visible and clearable until a successful response.
        return Set(available + [selected].compactMap { $0 })
            .sorted { $0.rawValue > $1.rawValue }
    }
}

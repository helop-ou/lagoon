import Foundation
import Observation

@Observable
final class HomeViewModel {
    struct LibraryRail: Identifiable {
        let id: String
        let title: String
        let items: [MediaItem]
    }

    var resume: [MediaItem] = []
    var nextUp: [MediaItem] = []
    var latestRails: [LibraryRail] = []
    var heroItems: [MediaItem] = []
    var isLoading = true
    var errorMessage: String?

    private var hasLoaded = false

    func load(client: JellyfinClient) async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        do {
            let libraries = try await client.userViews()
                .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }

            async let resumeItems = client.resumeItems()
            async let nextUpItems = client.nextUp()

            var rails: [LibraryRail] = []
            try await withThrowingTaskGroup(of: (Int, LibraryRail).self) { group in
                for (index, library) in libraries.enumerated() {
                    group.addTask {
                        let items = try await client.latest(parentId: library.id)
                        let title = "Recently Added" + (library.name.map { " in \($0)" } ?? "")
                        return (index, LibraryRail(id: library.id, title: title, items: items))
                    }
                }
                var collected: [(Int, LibraryRail)] = []
                for try await entry in group {
                    collected.append(entry)
                }
                rails = collected.sorted { $0.0 < $1.0 }.map(\.1)
            }

            resume = try await resumeItems
            nextUp = try await nextUpItems
            latestRails = rails
            heroItems = Array(
                rails.flatMap(\.items)
                    .filter { $0.backdropImageTags?.isEmpty == false && $0.overview != nil }
                    .shuffled()
                    .prefix(6)
            )
        } catch {
            hasLoaded = false
            errorMessage = "Couldn't load your library."
        }
        isLoading = false
    }

    func retry(client: JellyfinClient) async {
        hasLoaded = false
        await load(client: client)
    }

    /// Cheap re-fetch of the progress-driven rails when the screen reappears
    /// (e.g. returning from playback).
    func refreshProgress(client: JellyfinClient) async {
        guard hasLoaded, !isLoading else { return }
        async let resumeItems = client.resumeItems()
        async let nextUpItems = client.nextUp()
        if let refreshed = try? await (resume: resumeItems, nextUp: nextUpItems) {
            resume = refreshed.resume
            nextUp = refreshed.nextUp
        }
    }
}

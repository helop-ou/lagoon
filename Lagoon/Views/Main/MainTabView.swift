import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(DeepLinkRouter.self) private var deepLinks
    @State private var libraries: [LibraryTab] = []
    @State private var playerItem: PlayerItem?
    @State private var deepLinkError: String?
    @State private var deepLinkRetry = 0

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack {
                    HomeView()
                        .navigationDestination(for: MediaItem.self) { ItemDetailRouter(item: $0) }
                }
            }

            ForEach(libraries) { library in
                Tab(library.name ?? "Library", systemImage: icon(for: library)) {
                    NavigationStack {
                        LibraryView(library: library)
                            .navigationDestination(for: MediaItem.self) { ItemDetailRouter(item: $0) }
                    }
                }
            }

            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                NavigationStack {
                    SearchView()
                        .navigationDestination(for: MediaItem.self) { ItemDetailRouter(item: $0) }
                }
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .task {
            await loadLibraries()
        }
        // Headless hardware harness: resolve a named library item through
        // the app's existing signed-in client, then present the same player
        // path a user selection would. There is intentionally no Settings
        // UI for this launch-only diagnostic hook.
        .task {
            await launchBenchItemIfRequested()
        }
        // Presented from the TabView rather than a screen, so a Top Shelf
        // selection resumes playback whichever tab happens to be showing.
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem) { item in
            VideoPlayerView(playerItem: item)
                .preferredColorScheme(.dark)
        }
        // Runs once the session exists: on a cold launch the request is
        // made before there is a client to fetch with, so it waits here
        // instead of being dropped.
        .task(id: "\(deepLinks.pendingItemID ?? ""):\(deepLinkRetry)") {
            guard let id = deepLinks.pendingItemID else { return }
            do {
                let item = try await session.client.item(id: id)
                guard !Task.isCancelled, deepLinks.pendingItemID == id else { return }
                playerItem = PlayerItem(media: item)
                deepLinks.pendingItemID = nil
                deepLinkError = nil
            } catch is CancellationError {
            } catch {
                guard deepLinks.pendingItemID == id else { return }
                deepLinkError = "The item couldn't be loaded. Check the server connection and try again."
            }
        }
        .alert("Couldn't Open Item", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("Try Again") {
                deepLinkError = nil
                deepLinkRetry += 1
            }
            Button("Cancel", role: .cancel) {
                deepLinkError = nil
                deepLinks.pendingItemID = nil
            }
        } message: {
            Text(deepLinkError ?? "The item couldn't be loaded.")
        }
    }

    /// Tabs are the app's *navigation*, not a content rail, so a transient
    /// failure must never collapse them (HEL-61). This used to be a one-shot
    /// `try?` assigning `[]`, which meant a single unlucky request at launch
    /// removed Movies and Shows for the rest of the session — and it failed
    /// in exactly the situation where recovery is likely: a server slow to
    /// wake, or a TV rejoining wi-fi as the app foregrounds.
    ///
    /// So: never assign on failure, and keep retrying with backoff until the
    /// server answers.
    private func loadLibraries() async {
        // Draw last session's tabs straight away; the fetch reconciles a
        // moment later. Without this the bar visibly pops from three tabs
        // to five on every cold start (HEL-61).
        if libraries.isEmpty {
            libraries = session.cachedLibraries()
        }
        var delay = Duration.seconds(2)
        while !Task.isCancelled {
            if let views = try? await session.client.userViews() {
                // Assigning only on success is what distinguishes an empty
                // library from a failed fetch: an empty result here really
                // is empty, and clears the cache with it.
                let tabs = views
                    .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }
                    .map(LibraryTab.init)
                libraries = tabs
                session.cacheLibraries(tabs)
                return
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func launchBenchItemIfRequested() async {
        let regressionRun = UserDefaults.standard.bool(forKey: "debug.playerRegression")
        guard (UserDefaults.standard.bool(forKey: "debug.frameLossBench") || regressionRun),
              deepLinks.pendingItemID == nil,
              let term = UserDefaults.standard.string(forKey: "debug.benchSearchTerm")?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else { return }

        let requestedSeries = UserDefaults.standard.string(forKey: "debug.regressionSeriesName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindSkippableEpisode"),
           let requestedSeries,
           !requestedSeries.isEmpty {
            guard let seriesPage = try? await session.client.items(
                includeTypes: [.series],
                searchTerm: requestedSeries,
                limit: 20
            ),
            let series = seriesPage.items.first(where: {
                $0.name?.compare(
                    requestedSeries,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }),
            let episodes = try? await session.client.episodes(seriesId: series.id, seasonId: nil) else {
                print("RegressionResolve failed series=\"\(requestedSeries)\"")
                return
            }
            for episode in episodes {
                let segments = await session.client.mediaSegments(itemId: episode.id)
                if segments.contains(where: { $0.kind.isSkippable }) {
                    print("RegressionResolve skippable series=\"\(requestedSeries)\" title=\"\(episode.name ?? "?")\" id=\(episode.id)")
                    playerItem = PlayerItem(media: episode, startFromBeginning: true)
                    return
                }
            }
            print("RegressionResolve no skippable episode series=\"\(requestedSeries)\"")
            return
        }

        guard let page = try? await session.client.items(
            includeTypes: regressionRun ? [.movie, .episode] : [.movie],
            searchTerm: term,
            limit: regressionRun ? 100 : 20
        ) else {
            print("BenchResolve failed term=\"\(term)\"")
            return
        }
        let requestedYear = UserDefaults.standard.integer(forKey: "debug.benchProductionYear")
        let candidates = page.items.filter {
            $0.name?.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (requestedSeries?.isEmpty != false
                    || $0.seriesName?.compare(
                        requestedSeries!,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame)
        }
        let item = candidates.first(where: { requestedYear <= 0 || $0.productionYear == requestedYear })
            ?? candidates.first
        guard let item else {
            print("BenchResolve no exact match term=\"\(term)\" year=\(requestedYear)")
            return
        }
        print("BenchResolve title=\"\(item.name ?? term)\" year=\(item.productionYear ?? 0) id=\(item.id)")
        playerItem = PlayerItem(media: item, startFromBeginning: regressionRun)
    }

    private func icon(for library: LibraryTab) -> String {
        library.collectionType == "tvshows" ? "tv" : "film"
    }
}

/// Routes an item to the right detail screen off its type.
struct ItemDetailRouter: View {
    let item: MediaItem

    var body: some View {
        switch item.type {
        case .series:
            SeriesDetailView(item: item)
        default:
            ItemDetailView(item: item)
        }
    }
}

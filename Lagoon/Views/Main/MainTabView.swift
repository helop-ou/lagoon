import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(DeepLinkRouter.self) private var deepLinks
    @State private var libraries: [LibraryTab] = []
    @State private var playerItem: PlayerItem?

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
        .task(id: deepLinks.pendingItemID) {
            guard let id = deepLinks.pendingItemID else { return }
            // Clear *after* the fetch, never before: this task is keyed on
            // `pendingItemID`, so nilling it first cancels the very request
            // it is waiting on and the link silently does nothing (the
            // fetch died with -999 the first time round).
            defer { deepLinks.pendingItemID = nil }
            guard let item = try? await session.client.item(id: id) else { return }
            playerItem = PlayerItem(media: item)
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

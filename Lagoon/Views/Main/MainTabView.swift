import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @State private var libraries: [MediaItem] = []

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
        var delay = Duration.seconds(2)
        while !Task.isCancelled {
            if let views = try? await session.client.userViews() {
                libraries = views.filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }
                return
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func icon(for library: MediaItem) -> String {
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

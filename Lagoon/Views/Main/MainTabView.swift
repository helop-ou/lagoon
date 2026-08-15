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
            libraries = (try? await session.client.userViews())?
                .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") } ?? []
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

import SwiftUI

/// Every browsable-content stack speaks one route language. A stack must not
/// mix destination-owned links with value-owned links: doing so can reorder
/// nested destinations when a parent link refreshes on tvOS.
nonisolated enum ContentNavigationRoute: Hashable {
    case item(MediaItem)
    case genre(name: String, includeTypes: [MediaItemType])
    case search(String)
    #if os(iOS)
    /// The offline downloads list (tvOS has no downloads).
    case downloads
    #endif

    // Route identity is the item id, however stale the carried copy is; the
    // detail page re-fetches. `MediaItem` itself still compares by value.
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.item(a), .item(b)):
            a.id == b.id
        case let (.genre(name, includeTypes), .genre(otherName, otherIncludeTypes)):
            name == otherName && includeTypes == otherIncludeTypes
        case let (.search(query), .search(other)):
            query == other
        #if os(iOS)
        case (.downloads, .downloads):
            true
        #endif
        default:
            false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .item(let item):
            hasher.combine(0)
            hasher.combine(item.id)
        case .genre(let name, let includeTypes):
            hasher.combine(1)
            hasher.combine(name)
            hasher.combine(includeTypes)
        case .search(let query):
            hasher.combine(2)
            hasher.combine(query)
        #if os(iOS)
        case .downloads:
            hasher.combine(3)
        #endif
        }
    }
}

private struct ContentNavigationDestination: View {
    let route: ContentNavigationRoute

    var body: some View {
        switch route {
        case .item(let item):
            ItemDetailRouter(item: item)
                .detailPageChrome()
        case .genre(let name, let includeTypes):
            GenreLibraryView(genre: name, includeTypes: includeTypes)
        case .search(let query):
            SearchResultsView(query: query, source: .library)
        #if os(iOS)
        case .downloads:
            DownloadsView()
        #endif
        }
    }
}

extension View {
    /// Register once at each NavigationStack root, never inside a lazy rail or
    /// grid, so every push appends to one path and Back pops exactly one.
    func contentNavigationDestinations() -> some View {
        navigationDestination(for: ContentNavigationRoute.self) { route in
            ContentNavigationDestination(route: route)
        }
    }
}

extension EnvironmentValues {
    /// Opens "Who's watching?" over the app, keeping the current profile.
    /// `MainTabView` provides the action.
    @Entry var openProfilePicker: (@MainActor () -> Void)?
}

#if os(iOS)
extension EnvironmentValues {
    /// Shows the downloads list on the Library tab. Settings cannot push it:
    /// its stack uses destination-owned links, and mixing in value routes
    /// lost pushes. `MainTabView` provides the action.
    @Entry var showDownloadsList: (@MainActor () -> Void)?
}
#endif

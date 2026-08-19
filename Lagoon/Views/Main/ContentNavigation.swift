import SwiftUI

/// Every browsable-content stack speaks one route language. A stack must not
/// mix destination-owned links with value-owned links: doing so can reorder
/// nested destinations when a parent link refreshes on tvOS.
nonisolated enum ContentNavigationRoute: Hashable {
    case item(MediaItem)
    case genre(name: String, includeTypes: [MediaItemType])
}

private struct ContentNavigationDestination: View {
    let route: ContentNavigationRoute

    var body: some View {
        switch route {
        case .item(let item):
            ItemDetailRouter(item: item)
        case .genre(let name, let includeTypes):
            GenreLibraryView(genre: name, includeTypes: includeTypes)
        }
    }
}

extension View {
    /// Register once at each NavigationStack root, never inside a lazy rail or
    /// grid. Descendant details (including More Like This) then append to the
    /// same ordered path and Back always removes exactly one route.
    func contentNavigationDestinations() -> some View {
        navigationDestination(for: ContentNavigationRoute.self) { route in
            ContentNavigationDestination(route: route)
        }
    }
}

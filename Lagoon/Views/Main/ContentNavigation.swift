import SwiftUI

/// Every browsable-content stack speaks one route language. A stack must not
/// mix destination-owned links with value-owned links: doing so can reorder
/// nested destinations when a parent link refreshes on tvOS.
nonisolated enum ContentNavigationRoute: Hashable {
    case item(MediaItem)
    case genre(name: String, includeTypes: [MediaItemType])

    // A route carries whatever copy of the item a rail had, and the detail
    // page re-fetches the rest. Two routes to the same item are the same
    // destination however stale one copy's user data is, so identity here is
    // the item's id; `MediaItem` itself compares by value (HEL-132).
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case let (.item(a), .item(b)):
            a.id == b.id
        case let (.genre(name, includeTypes), .genre(otherName, otherIncludeTypes)):
            name == otherName && includeTypes == otherIncludeTypes
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
        }
    }
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

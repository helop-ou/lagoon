import SwiftUI

nonisolated enum SeerrNavigationRoute: Hashable {
    case settings
    case catalog(SeerrCatalogSource)
    case media(id: Int, type: SeerrMediaType)
    case requests
    case request(SeerrMediaRequest)
    case jellyfinItem(MediaItem)
    case search(String)
}

private struct SeerrNavigationDestination: View {
    let route: SeerrNavigationRoute

    var body: some View {
        switch route {
        case .settings:
            SeerrSettingsView()
        case .catalog(let source):
            SeerrCatalogView(source: source)
        case .media(let id, let type):
            SeerrMediaDetailView(mediaID: id, mediaType: type)
        case .requests:
            SeerrRequestsView()
        case .request(let request):
            SeerrRequestDetailView(request: request)
        case .jellyfinItem(let item):
            ItemDetailRouter(item: item)
        case .search(let query):
            SearchResultsView(query: query, source: .seerr)
        }
    }
}

extension View {
    func seerrNavigationDestinations() -> some View {
        navigationDestination(for: SeerrNavigationRoute.self) { route in
            SeerrNavigationDestination(route: route)
        }
    }
}

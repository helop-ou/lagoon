import SwiftUI

nonisolated enum SeerrNavigationRoute: Hashable {
    case settings
    case catalog(SeerrCatalogSource)
    case media(id: Int, type: SeerrMediaType)
    case requests
    case request(SeerrMediaRequest)
    case jellyfinItem(MediaItem)
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

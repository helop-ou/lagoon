import SwiftUI

/// A Home Screen Sections row of titles from Sonarr, Radarr or Seerr. None
/// is in the library, so a card shows the plugin's poster and opens Seerr's
/// page when there is one to open, and nothing otherwise.
struct ExternalSectionRail: View {
    let title: String
    let items: [JellyfinClient.ExternalSectionItem]

    var body: some View {
        if !items.isEmpty {
            RailShelf(title: title, alignment: .top) {
                ForEach(items) { item in
                    ExternalSectionCard(item: item)
                }
            }
        }
    }
}

private struct ExternalSectionCard: View {
    let item: JellyfinClient.ExternalSectionItem
    @Environment(\.jellyfinClient) private var client
    @Environment(SeerrSessionStore.self) private var seerr
    let layout = PosterLayout()

    var body: some View {
        PosterCardShell(
            route: route,
            imageURL: item.posterPath.flatMap { client?.serverRelativeURL($0) },
            maxPixelSize: layout.imageSize,
            title: item.title,
            subtitle: item.subtitle,
            accessibilityLabel: item.title,
            accessibilityValue: item.subtitle,
            accessibilityIdentifier: "home.external.\(item.id)"
        )
    }

    /// Upcoming titles have no page anywhere Lagoon can reach, and Seerr's
    /// need Lagoon signed in to Seerr.
    private var route: SeerrNavigationRoute? {
        guard seerr.isConnected, let id = item.seerrID, let type = item.seerrType else { return nil }
        return .media(id: id, type: type)
    }
}

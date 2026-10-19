import SwiftUI

/// Where a Home title from Sonarr, Radarr or Seerr leads while Lagoon is not
/// signed in to Seerr. Seerr shows its titles only to a signed-in user, so
/// this is Seerr's sign-in until there is one, then the title's own page in
/// its place, so Back returns to Home.
struct SeerrSignInGate: View {
    let item: JellyfinClient.ExternalSectionItem
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var lookup: Lookup = .pending
    @State private var attempt = 0

    private enum Lookup: Equatable {
        case pending
        case found(ExternalSeerrTitle)
        case missing
    }

    var body: some View {
        if seerr.isConnected {
            Group {
                switch lookup {
                case .pending:
                    LoadingView()
                case .found(let title):
                    SeerrMediaDetailView(mediaID: title.id, mediaType: title.mediaType)
                        .detailPageChrome()
                case .missing:
                    ErrorStateView(
                        systemImage: "magnifyingglass",
                        message: "Seerr has no page for \(item.title).",
                        retry: { attempt += 1 }
                    )
                }
            }
            .task(id: "\(seerr.user?.id ?? -1):\(attempt)") {
                lookup = .pending
                lookup = await find().map(Lookup.found) ?? .missing
            }
        } else {
            SeerrSettingsView(suggestedAddress: item.seerrAddress)
        }
    }

    /// Seerr's own titles carry their id; the page fetches the rest.
    private func find() async -> ExternalSeerrTitle? {
        if let id = item.seerrID, let type = item.seerrType {
            return ExternalSeerrTitle(id: id, mediaType: type, backdropPath: nil)
        }
        return await ExternalSeerrMatcher.find(item, seerr: seerr.client)
    }
}

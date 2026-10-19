import SwiftUI

/// Detail page for playable items — movies and standalone episodes.
struct ItemDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(SyncPlayStore.self) private var syncPlay
    @State private var detail: MediaItem?
    @State private var similar: [MediaItem] = []
    @State private var playerItem: PlayerItem?

    private var displayed: MediaItem { detail ?? item }

    var body: some View {
        DetailPageScaffold(
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth),
            posterURL: session.client.imageURL(for: displayed, kind: .poster, maxWidth: Metrics.detailPosterRequestWidth)
        ) {
            DetailHeader(item: displayed) { playButtons }
            CastStrip(people: displayed.people ?? [])
            MediaRail(title: String(localized: "More Like This"), items: similar)
        }
        .task(id: item.id) {
            await loadFromServer()
            #if os(iOS)
            await DownloadStore.shared.refreshPermission(client: session.client)
            #endif
            // The control renders nothing until this answers, so it cannot
            // run the task itself.
            await syncPlay.refreshAvailability()
        }
        .task(id: item.id) {
            // Measured while the page is read, so Play rarely waits on it.
            _ = await session.client.connectionBitrateCeiling()
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await loadFromServer() }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: {
            Task {
                // Read the item back only once the stop report has landed.
                await session.client.playbackReports.settle()
                if let fresh = try? await session.client.item(id: item.id) {
                    detail = fresh
                }
            }
        })
    }

    /// A failed refresh keeps what is on screen. A successful one replaces
    /// the whole value, including progress from other clients.
    private func loadFromServer() async {
        let generation = serverSync.generation
        async let refreshedDetail = try? session.client.item(id: item.id)
        async let refreshedSimilar = loadSimilarFromServer()
        let (newDetail, newSimilar) = await (refreshedDetail, refreshedSimilar)
        guard generation == serverSync.generation else { return }
        if let newDetail { detail = newDetail }
        if let newSimilar { similar = newSimilar }
    }

    private func loadSimilarFromServer() async -> [MediaItem]? {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debug.navigationRegression"),
           let page = try? await session.client.items(
               includeTypes: [.movie],
               limit: 10
           ) {
            // The demo server's recommendations are sparse. Real catalog items
            // let the regression exercise Detail -> Detail -> Back.
            return Array(page.items.filter { $0.id != item.id }.prefix(6))
        }
        #endif
        return try? await session.client.similarItems(itemId: item.id)
    }

    /// A downloaded title's own position outranks the server's, which may be
    /// stale or unreachable. The controller applies the same order.
    private var resumeTicks: Int64? {
        #if os(iOS)
        if let local = DownloadStore.shared.entry(for: displayed.id)?.localPositionTicks, local > 0 {
            return local
        }
        #endif
        guard let ticks = displayed.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    /// Play leads so it takes first focus. Otherwise Select on arrival marks
    /// the film watched instead of playing it.
    private var playButtons: some View {
        DetailPlayActions(
            resumes: resumeTicks != nil,
            caption: resumeTicks.map { String(localized: "Resume from \(Ticks.timestamp($0))") },
            play: { playerItem = PlayerItem(media: displayed) },
            playFromBeginning: resumeTicks == nil
                ? nil
                : { playerItem = PlayerItem(media: displayed, startFromBeginning: true) }
        ) {
            actionRow
                #if os(tvOS)
                .padding(.leading, Metrics.Space.l)
                #endif
            TrailerButton(trailers: displayed.remoteTrailers)
            #if os(iOS)
            DownloadControl(item: displayed)
            #endif
            WatchTogetherControl(item: displayed, startPositionTicks: resumeTicks ?? 0)
        }
    }

    private var actionRow: some View {
        ItemActionRow(item: displayed) {
            // On failure the row keeps the viewer's choice until a later read.
            guard let fresh = try? await session.client.item(id: item.id) else { return false }
            detail = fresh
            return true
        }
    }
}

import SwiftUI

/// Detail page for playable items — movies and standalone episodes.
struct ItemDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @State private var detail: MediaItem?
    @State private var similar: [MediaItem] = []
    @State private var playerItem: PlayerItem?

    private var displayed: MediaItem { detail ?? item }

    var body: some View {
        DetailPageScaffold(
            backdropURL: session.client.imageURL(for: displayed, kind: .backdrop, maxWidth: 1920)
        ) {
            DetailHeader(item: displayed) { playButtons }
            CastStrip(people: displayed.people ?? [])
            MediaRail(title: String(localized: "More Like This"), items: similar)
        }
        .task(id: item.id) {
            await loadFromServer()
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await loadFromServer() }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: {
            Task {
                // The stop report that moves the resume point is still in
                // flight here; read the item back only once it has landed
                // (HEL-132).
                await session.client.playbackReports.settle()
                if let fresh = try? await session.client.item(id: item.id) {
                    detail = fresh
                }
            }
        })
    }

    /// Refreshing in place preserves the detail and recommendation rail when
    /// a foreground request fails. A successful response replaces the whole
    /// value, including watch progress changed in another client (HEL-135).
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
            // The public demo's recommendation endpoint is intentionally
            // sparse. Use different real catalog items so the regression can
            // always exercise Detail -> Detail -> Back ordering.
            return Array(page.items.filter { $0.id != item.id }.prefix(6))
        }
        #endif
        return try? await session.client.similarItems(itemId: item.id)
    }

    private var resumeTicks: Int64? {
        guard let ticks = displayed.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    private var playButtons: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            actions

            if let resumeTicks {
                Text("Resume from \(Self.timestamp(resumeTicks))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        #if os(tvOS)
        // One row, Play first. Stacked above the play buttons the toggles
        // also took *first focus*, so arriving and pressing Select marked the
        // film watched instead of playing it.
        HStack(spacing: Metrics.Space.l) {
            playButton
            fromBeginningButton
            actionRow
                .padding(.leading, Metrics.Space.l)
        }
        #else
        // Lead with the primary action on touch too. Most items fit all
        // controls on one line. Keep Resume and From Beginning together when
        // they fit, moving the toggles below before stacking every button.
        AdaptiveActionStack {
            AdaptiveActionStack {
                playButton
                fromBeginningButton
            }
            actionRow
            #if DEBUG
            downloadSpikeMenu
            #endif
        }
        #endif
    }

    #if DEBUG && os(iOS)
    /// HEL-166 spike: take this title off the server as the original file
    /// or a progressive transcode. Debug builds only; the real feature gets
    /// its own control.
    private var downloadSpikeMenu: some View {
        Menu {
            Button("Download original") { startSpikeDownload(.original) }
            Button("Download transcode (1080p, 8 Mbps)") { startSpikeDownload(.transcode) }
        } label: {
            Image(systemName: DownloadSpikeStore.shared.completedLocalURL(itemID: displayed.id) == nil
                  ? "arrow.down.circle" : "arrow.down.circle.fill")
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Download (spike)")
    }

    private func startSpikeDownload(_ kind: DownloadSpikeEntry.Kind) {
        Task {
            // The detail read carries media sources; a rail item does not.
            let fresh = displayed.mediaSources == nil ? try? await session.client.item(id: item.id) : displayed
            guard let source = (fresh ?? displayed).mediaSources?.first else { return }
            DownloadSpikeStore.shared.start(item: displayed, source: source, kind: kind, client: session.client)
        }
    }
    #endif

    private var actionRow: some View {
        ItemActionRow(item: displayed) {
            // A failed re-read keeps the detail on screen; the row keeps the
            // viewer's choice until a later read succeeds.
            guard let fresh = try? await session.client.item(id: item.id) else { return false }
            detail = fresh
            return true
        }
    }

    private var playButton: some View {
        Button {
            playerItem = PlayerItem(media: displayed)
        } label: {
            Label(resumeTicks == nil ? "Play" : "Resume", systemImage: "play.fill")
        }
        .buttonStyle(.glass)
    }

    @ViewBuilder
    private var fromBeginningButton: some View {
        if resumeTicks != nil {
            Button {
                playerItem = PlayerItem(media: displayed, startFromBeginning: true)
            } label: {
                Label("From Beginning", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
        }
    }

    private static func timestamp(_ ticks: Int64) -> String {
        let seconds = Int(Ticks.seconds(ticks))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

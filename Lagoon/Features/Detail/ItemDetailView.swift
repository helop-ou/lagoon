import SwiftUI

/// Detail page for playable items — movies and standalone episodes.
struct ItemDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @Environment(SyncPlayStore.self) private var syncPlay
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
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

    /// A failed refresh keeps what is on screen; a successful one replaces
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
            // The demo server's recommendations are sparse; real catalog items
            // let the regression exercise Detail -> Detail -> Back.
            return Array(page.items.filter { $0.id != item.id }.prefix(6))
        }
        #endif
        return try? await session.client.similarItems(itemId: item.id)
    }

    /// A downloaded title's own position outranks the server's, which may be
    /// stale or unreachable; the controller applies the same order.
    private var resumeTicks: Int64? {
        #if os(iOS)
        if let local = DownloadStore.shared.entry(for: displayed.id)?.localPositionTicks, local > 0 {
            return local
        }
        #endif
        guard let ticks = displayed.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    /// The resume caption sits under the row on wide layouts and under the
    /// Resume pill on a phone.
    @ViewBuilder
    private var playButtons: some View {
        #if os(iOS)
        if !usesLeadingColumn {
            actions
        } else {
            captionedActions
        }
        #else
        captionedActions
        #endif
    }

    private var captionedActions: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            actions
            resumeCaption
        }
    }

    @ViewBuilder
    private var resumeCaption: some View {
        if let resumeTicks {
            Text("Resume from \(Self.timestamp(resumeTicks))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    #if os(iOS)
    private var usesLeadingColumn: Bool {
        DetailLayout.usesLeadingColumn(horizontalSizeClass)
    }
    #endif

    /// Play leads so it takes first focus; otherwise Select on arrival marks
    /// the film watched instead of playing it.
    private var actions: some View {
        DetailActionLayout {
            #if os(iOS)
            if usesLeadingColumn {
                playButton
            } else {
                // The caption hangs under the pill alone so the row stays level.
                VStack(spacing: Metrics.Space.xs) {
                    playButton
                        .alignmentGuide(.detailPillCenter) { $0[VerticalAlignment.center] }
                    resumeCaption
                }
            }
            #else
            playButton
            #endif
        } secondary: {
            fromBeginningButton
            actionRow
                #if os(tvOS)
                .padding(.leading, Metrics.Space.l)
                #endif
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

    private var playButton: some View {
        Button {
            playerItem = PlayerItem(media: displayed)
        } label: {
            Label(resumeTicks == nil ? "Play" : "Resume", systemImage: "play.fill")
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
        #if os(iOS)
        .accessibilityIdentifier("detail.play")
        #endif
    }

    /// A pill beside Play on TV and wide iPad; a circle on a phone, where a
    /// pill folds the four-control row into a column.
    @ViewBuilder
    private var fromBeginningButton: some View {
        if resumeTicks != nil {
            #if os(iOS)
            if usesLeadingColumn {
                Button {
                    playerItem = PlayerItem(media: displayed, startFromBeginning: true)
                } label: {
                    Label("From Beginning", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
            } else {
                DetailCircleButton {
                    playerItem = PlayerItem(media: displayed, startFromBeginning: true)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("From Beginning")
            }
            #else
            Button {
                playerItem = PlayerItem(media: displayed, startFromBeginning: true)
            } label: {
                Label("From Beginning", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            #endif
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

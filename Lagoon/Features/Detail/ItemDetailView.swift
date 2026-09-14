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
            // Asked here for the reason the download permission is: the
            // control renders nothing until the answer is in, and a task
            // on a view that renders nothing never runs (HEL-172).
            await syncPlay.refreshAvailability()
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

    /// Where Resume would start. A downloaded title's own recorded position
    /// outranks the server's, which may be stale or unreachable (HEL-166);
    /// the controller applies the same order.
    private var resumeTicks: Int64? {
        #if os(iOS)
        if let local = DownloadStore.shared.entry(for: displayed.id)?.localPositionTicks, local > 0 {
            return local
        }
        #endif
        guard let ticks = displayed.userData?.playbackPositionTicks, ticks > 0 else { return nil }
        return ticks
    }

    /// The actions and, once there is a resume point, where Resume starts
    /// from. Wide compositions keep that caption under the row; on a phone
    /// it belongs to the Resume pill (HEL-169) and sits centred under it in
    /// both orientations.
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

    /// Play first everywhere it shares a row, so it takes first focus:
    /// stacked above the play buttons the toggles also took *first focus*,
    /// so arriving and pressing Select marked the film watched instead of
    /// playing it. On a phone the resume caption belongs to the pill
    /// (HEL-169); the shared layout puts the pill where each composition
    /// wants it.
    private var actions: some View {
        DetailActionLayout {
            #if os(iOS)
            if usesLeadingColumn {
                playButton
            } else {
                // The circles align with the pill's centre, not the centre
                // of the pill plus its caption, so the caption hangs under
                // the pill alone and the row itself stays level.
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
                .detailPrimaryLabel()
        }
        .detailPrimaryButton()
        #if os(iOS)
        .accessibilityIdentifier("detail.play")
        #endif
    }

    /// A labelled pill beside Play on the TV and a wide iPad; a glass
    /// circle in the phone's row of secondary controls, where a pill made
    /// the row fold into a column once four controls shared it.
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

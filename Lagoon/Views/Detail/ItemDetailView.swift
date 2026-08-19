import SwiftUI

/// Detail page for playable items — movies and standalone episodes.
struct ItemDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
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
            detail = try? await session.client.item(id: item.id)
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debug.navigationRegression"),
               let page = try? await session.client.items(
                   includeTypes: [.movie],
                   limit: 10
               ) {
                // The public demo's recommendation endpoint is intentionally
                // sparse. Use different real catalog items so the regression
                // can always exercise Detail -> Detail -> Back ordering.
                similar = Array(page.items.filter { $0.id != item.id }.prefix(6))
                return
            }
            #endif
            similar = (try? await session.client.similarItems(itemId: item.id)) ?? []
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem, onDismiss: {
            Task { detail = try? await session.client.item(id: item.id) }
        }) { player in
            VideoPlayerView(playerItem: player)
                .preferredColorScheme(.dark)
        }
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
        // controls on one line; a resumed item with the longer From Beginning
        // label falls back cleanly without putting watched/favourite first.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Metrics.detailActionSpacing) {
                playButton
                fromBeginningButton
                actionRow
            }

            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                HStack(spacing: Metrics.Space.l) {
                    playButton
                    fromBeginningButton
                }
                actionRow
            }
        }
        #endif
    }

    private var actionRow: some View {
        ItemActionRow(item: displayed) {
            detail = try? await session.client.item(id: item.id)
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

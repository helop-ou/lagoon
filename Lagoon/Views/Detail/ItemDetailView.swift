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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button {
                    playerItem = PlayerItem(media: displayed)
                } label: {
                    Label(resumeTicks == nil ? "Play" : "Resume", systemImage: "play.fill")
                }
                .buttonStyle(.glass)

                if resumeTicks != nil {
                    Button {
                        playerItem = PlayerItem(media: displayed, startFromBeginning: true)
                    } label: {
                        Label("From Beginning", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.glass)
                }
            }

            if let resumeTicks {
                Text("Resume from \(Self.timestamp(resumeTicks))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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

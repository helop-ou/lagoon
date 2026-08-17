import SwiftUI

/// Watched and favourite toggles above the play buttons (HEL-40), in the
/// shape the HEL-46 reference uses: a row of small circular icon buttons.
///
/// Both are genuine toggles rather than one-way actions. Marking something
/// watched that you never started is the point — it's how a film leaves the
/// Continue Watching rail, and how you tell the server you've seen something
/// you watched elsewhere. Unmarking puts it back.
///
/// State is optimistic: the icon flips immediately and reverts if the server
/// refuses, because a toggle that waits on a round trip feels broken.
struct ItemActionRow: View {
    let item: MediaItem
    /// Called after the server has accepted a change, so the page can
    /// re-fetch and the rails behind it can catch up.
    let onChange: () async -> Void

    @Environment(SessionStore.self) private var session
    @State private var played: Bool?
    @State private var favorite: Bool?

    private var isPlayed: Bool { played ?? item.userData?.played ?? false }
    private var isFavorite: Bool { favorite ?? item.userData?.isFavorite ?? false }

    var body: some View {
        HStack(spacing: 16) {
            toggle(
                on: isPlayed,
                symbol: "checkmark",
                label: isPlayed ? "Mark as unwatched" : "Mark as watched"
            ) {
                let target = !isPlayed
                played = target
                do {
                    try await session.client.setPlayed(target, itemId: item.id)
                    await onChange()
                } catch {
                    played = !target
                }
            }

            toggle(
                on: isFavorite,
                symbol: isFavorite ? "star.fill" : "star",
                label: isFavorite ? "Remove from favorites" : "Add to favorites"
            ) {
                let target = !isFavorite
                favorite = target
                do {
                    try await session.client.setFavorite(target, itemId: item.id)
                    await onChange()
                } catch {
                    favorite = !target
                }
            }
        }
        // A fresh item carries fresh server state; drop the local override so
        // the row doesn't keep showing the last page's answer.
        .onChange(of: item.id) { _, _ in
            played = nil
            favorite = nil
        }
    }

    private func toggle(
        on: Bool,
        symbol: String,
        label: LocalizedStringKey,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                // Set state reads through weight, not colour: a tinted label
                // would vanish inside the focused lozenge (HEL-50).
                .fontWeight(on ? .bold : .regular)
                .opacity(on ? 1 : 0.55)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

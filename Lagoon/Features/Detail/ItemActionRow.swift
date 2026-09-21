import SwiftUI

/// Watched and favourite toggles above the play buttons: a row of small
/// circular icon buttons.
///
/// Both are genuine toggles rather than one-way actions. Marking something
/// watched that you never started is the point — it's how a film leaves the
/// Continue Watching rail, and how you tell the server you've seen something
/// you watched elsewhere. Unmarking puts it back.
///
/// State is optimistic: the icon flips immediately. `OptimisticToggleState`
/// owns what follows: a refusal reverts the icon and says so beneath
/// the row; an accepted change hands authority back to the server
/// once the page has re-read the item; a press during a request is dropped.
struct ItemActionRow: View {
    /// What the checkmark acts on. On a series page this is the episode you
    /// are about to play, not the show — marking "watched" next to a Play
    /// button that starts S1 E1 can only sensibly mean that episode.
    let playedItem: MediaItem
    /// What the star acts on — the show on a series page, since favouriting
    /// a single episode is nearly useless.
    let favoriteItem: MediaItem
    /// Called after the server has accepted a change, so the page can
    /// re-fetch and the rails behind it can catch up. Returns whether the
    /// re-fetch reached the screen: only then does the row let the server's
    /// flag replace the viewer's choice.
    let onChange: () async -> Bool

    init(item: MediaItem, playedItem: MediaItem? = nil, onChange: @escaping () async -> Bool) {
        self.favoriteItem = item
        self.playedItem = playedItem ?? item
        self.onChange = onChange
    }

    @Environment(SessionStore.self) private var session
    @State private var playedState = OptimisticToggleState()
    @State private var favoriteState = OptimisticToggleState()

    private var isPlayed: Bool { playedState.value(server: playedItem.userData?.played) }
    private var isFavorite: Bool { favoriteState.value(server: favoriteItem.userData?.isFavorite) }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
            HStack(spacing: Metrics.detailActionSpacing) {
                toggle(
                    on: isPlayed,
                    symbol: "checkmark",
                    label: isPlayed ? "Mark as unwatched" : "Mark as watched"
                ) {
                    await togglePlayed()
                }

                toggle(
                    on: isFavorite,
                    symbol: isFavorite ? "star.fill" : "star",
                    label: isFavorite ? "Remove from favorites" : "Add to favorites"
                ) {
                    await toggleFavorite()
                }
            }
            if let message = failureMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
                    .task(id: message) {
                        AccessibilityNotification.Announcement(message).post()
                        try? await Task.sleep(for: .seconds(Self.failureMessageSeconds))
                        withAnimation(.easeOut(duration: Motion.fast)) {
                            playedState.dismissFailure()
                            favoriteState.dismissFailure()
                        }
                    }
            }
        }
        .animation(.easeOut(duration: Motion.fast), value: failureMessage)
        // A fresh item carries fresh server state; drop the local override so
        // the row doesn't keep showing the last page's answer.
        .onChange(of: playedItem.id) { _, _ in playedState.itemChanged() }
        .onChange(of: favoriteItem.id) { _, _ in favoriteState.itemChanged() }
    }

    /// How long a refusal stays on screen. Long enough to read, short enough
    /// that the row is back to being a row before the next press.
    private static let failureMessageSeconds: Double = 4

    private var failureMessage: String? {
        if let refused = playedState.refusedTarget {
            return refused
                ? String(localized: "Couldn't mark as watched. Try again.")
                : String(localized: "Couldn't mark as unwatched. Try again.")
        }
        if let refused = favoriteState.refusedTarget {
            return refused
                ? String(localized: "Couldn't add to favorites. Try again.")
                : String(localized: "Couldn't remove from favorites. Try again.")
        }
        return nil
    }

    private func togglePlayed() async {
        guard let target = playedState.begin(server: playedItem.userData?.played) else { return }
        let itemID = playedItem.id
        do {
            try await session.client.setPlayed(target, itemId: itemID)
            let refreshed = await onChange()
            guard itemID == playedItem.id else { return }
            playedState.succeed(refreshed: refreshed)
        } catch {
            guard itemID == playedItem.id else { return }
            playedState.fail()
        }
    }

    private func toggleFavorite() async {
        guard let target = favoriteState.begin(server: favoriteItem.userData?.isFavorite) else { return }
        let itemID = favoriteItem.id
        do {
            try await session.client.setFavorite(target, itemId: itemID)
            let refreshed = await onChange()
            guard itemID == favoriteItem.id else { return }
            favoriteState.succeed(refreshed: refreshed)
        } catch {
            guard itemID == favoriteItem.id else { return }
            favoriteState.fail()
        }
    }

    @ViewBuilder
    private func toggle(
        on: Bool,
        symbol: String,
        label: LocalizedStringKey,
        action: @escaping () async -> Void
    ) -> some View {
        #if os(iOS)
        DetailCircleButton {
            Task { await action() }
        } label: {
            toggleGlyph(on: on, symbol: symbol)
        }
        .accessibilityLabel(label)
        #else
        Button {
            Task { await action() }
        } label: {
            toggleGlyph(on: on, symbol: symbol)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
        #endif
    }

    private func toggleGlyph(on: Bool, symbol: String) -> some View {
        Image(systemName: symbol)
            // Set state reads through weight, not colour: a tinted label
            // would vanish inside the focused lozenge.
            .fontWeight(on ? .bold : .regular)
            .opacity(on ? 1 : 0.55)
    }
}

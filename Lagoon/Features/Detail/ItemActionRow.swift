import SwiftUI

/// Watched and favourite toggles above the play buttons. State is optimistic;
/// see `OptimisticToggleState`.
struct ItemActionRow: View {
    /// What the checkmark acts on: on a series page, the episode Play starts.
    let playedItem: MediaItem
    /// What the star acts on: on a series page, the show.
    let favoriteItem: MediaItem
    /// Re-fetches after the server accepts a change. Returns whether the
    /// re-fetch reached the screen; only then does the server's flag replace
    /// the viewer's choice.
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
        // A new item drops the local override.
        .onChange(of: playedItem.id) { _, _ in playedState.itemChanged() }
        .onChange(of: favoriteItem.id) { _, _ in favoriteState.itemChanged() }
    }

    /// How long a refusal stays on screen.
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
            // Weight, not colour: a tinted label vanishes when focused.
            .fontWeight(on ? .bold : .regular)
            .opacity(on ? 1 : 0.55)
    }
}

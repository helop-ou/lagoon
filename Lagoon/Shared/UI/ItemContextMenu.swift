import SwiftUI

/// Long-press menu on any card: watched/unwatched and favourite, as in
/// `ItemActionRow`.
///
/// State is optimistic because the menu dismisses instantly. `onChange`
/// reconciles: the rails re-fetch and the card redraws from the server.
private struct ItemUserDataMenu: ViewModifier {
    let item: MediaItem
    let onChange: (() async -> Void)?

    @Environment(\.jellyfinClient) private var client
    @Environment(\.itemDownloads) private var downloads
    @State private var played: Bool?
    @State private var favorite: Bool?

    private var isPlayed: Bool { played ?? item.userData?.played ?? false }
    private var isFavorite: Bool { favorite ?? item.userData?.isFavorite ?? false }

    /// Episode cards get the checkmark only. Favourites are show-level, and
    /// don't retarget the star at `seriesId`: the card carries the episode's
    /// `userData`, so it can't know the show's state. The series page owns it.
    private var offersFavorite: Bool { item.type != .episode }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    mutate(
                        target: !isPlayed,
                        apply: { played = $0 },
                        send: { try await requireClient().setPlayed($0, itemId: item.id) }
                    )
                } label: {
                    Label(
                        isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                        systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle"
                    )
                }

                if offersFavorite {
                    Button {
                        mutate(
                            target: !isFavorite,
                            apply: { favorite = $0 },
                            send: { try await requireClient().setFavorite($0, itemId: item.id) }
                        )
                    } label: {
                        Label(
                            isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite ? "star.slash" : "star"
                        )
                    }
                }

                downloads?.contextMenuItems(for: item)
            }
            // Rails recycle card views, so drop an override from the
            // previous item. Same guard as `ItemActionRow`.
            .onChange(of: item.id) { _, _ in
                played = nil
                favorite = nil
            }
    }

    /// A hierarchy without a signed-in account has no client; the
    /// optimistic state then reverts.
    private func requireClient() throws -> JellyfinClient {
        guard let client else { throw CancellationError() }
        return client
    }

    private func mutate(
        target: Bool,
        apply: @escaping (Bool?) -> Void,
        send: @escaping (Bool) async throws -> Void
    ) {
        apply(target)
        Task {
            do {
                try await send(target)
                await onChange?()
                // Keep the override past the refresh: a list without
                // `onChange` never re-fetches, and the icon would revert.
            } catch {
                apply(!target)
            }
        }
    }
}

extension View {
    /// Attaches the watched/favourite long-press menu to a card. Pass
    /// `onChange` wherever the surrounding list can re-fetch itself.
    func itemUserDataMenu(item: MediaItem, onChange: (() async -> Void)? = nil) -> some View {
        modifier(ItemUserDataMenu(item: item, onChange: onChange))
    }
}

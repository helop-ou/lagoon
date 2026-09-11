import SwiftUI

/// Long-press menu on any card: mark watched/unwatched and favourite
/// (HEL-40). The same two mutations `ItemActionRow` offers on the detail
/// page, so saying "I've seen this" doesn't cost a trip into the item and
/// back — which is the whole point of a rail you're scanning.
///
/// State is optimistic for the same reason it is there: the menu dismisses
/// the instant you pick something, so a round trip would leave the card
/// looking unchanged. `onChange` is what actually reconciles — the rails
/// re-fetch and the card redraws from server truth a moment later.
private struct ItemUserDataMenu: ViewModifier {
    let item: MediaItem
    let onChange: (() async -> Void)?

    @Environment(SessionStore.self) private var session
    @State private var played: Bool?
    @State private var favorite: Bool?

    private var isPlayed: Bool { played ?? item.userData?.played ?? false }
    private var isFavorite: Bool { favorite ?? item.userData?.isFavorite ?? false }

    /// Episode cards get the checkmark only.
    ///
    /// Favouriting is a show-level gesture — `ItemActionRow`'s star targets
    /// the series for the same reason, and the Favorites rail lists movies
    /// and series only, so an episode-level star would land somewhere you
    /// could never see it. Retargeting the star at `seriesId` from here
    /// looks tempting and is worse: the card carries the *episode's*
    /// `userData`, so it cannot know whether the show is already
    /// favourited, and the toggle would point the wrong way half the time.
    /// One extra fetch per card to find out is not worth it. The series
    /// page owns that star.
    private var offersFavorite: Bool { item.type != .episode }

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button {
                    mutate(
                        target: !isPlayed,
                        apply: { played = $0 },
                        send: { try await session.client.setPlayed($0, itemId: item.id) }
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
                            send: { try await session.client.setFavorite($0, itemId: item.id) }
                        )
                    } label: {
                        Label(
                            isFavorite ? "Remove from Favorites" : "Add to Favorites",
                            systemImage: isFavorite ? "star.slash" : "star"
                        )
                    }
                }
            }
            // Rails recycle their card views as the list behind them changes,
            // so a stale local override would otherwise describe the previous
            // item. Same guard as `ItemActionRow`.
            .onChange(of: item.id) { _, _ in
                played = nil
                favorite = nil
            }
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
                // The override deliberately outlives the refresh: it already
                // agrees with what the server was just told, and dropping it
                // here would revert the icon on any card whose list has no
                // `onChange` to re-fetch with.
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

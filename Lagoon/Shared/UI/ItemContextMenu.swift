import SwiftUI
#if os(iOS)
import os
#endif

/// Long-press menu on any card: watched/unwatched and favourite, as in
/// `ItemActionRow`.
///
/// State is optimistic because the menu dismisses instantly. `onChange`
/// reconciles: the rails re-fetch and the card redraws from the server.
private struct ItemUserDataMenu: ViewModifier {
    let item: MediaItem
    let onChange: (() async -> Void)?

    @Environment(SessionStore.self) private var session
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

                #if os(iOS)
                downloadMenuItems
                #endif
            }
            // Rails recycle card views, so drop an override from the
            // previous item. Same guard as `ItemActionRow`.
            .onChange(of: item.id) { _, _ in
                played = nil
                favorite = nil
            }
            #if os(iOS)
            .task {
                // Warms the permission cache so the first long-press knows
                // whether to offer Download.
                if session.client.cachedContentDownloadingAllowed == nil {
                    _ = await session.client.canDownloadContent()
                }
                if session.client.cachedVideoTranscodingAllowed == nil {
                    _ = await session.client.canTranscodeForDownload()
                }
            }
            #endif
    }

    #if os(iOS)
    /// Movies and episodes only; others have no file of their own. A new
    /// download gets `DownloadControl`'s quality picker.
    @ViewBuilder
    private var downloadMenuItems: some View {
        if item.type == .movie || item.type == .episode {
            let store = DownloadStore.shared
            if store.isDownloaded(item.id) {
                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Label("Delete Download", systemImage: "arrow.down.circle.fill")
                }
            } else if store.entry(for: item.id) != nil {
                Button(role: .destructive) {
                    store.delete(item.id)
                } label: {
                    Label("Cancel Download", systemImage: "xmark.circle")
                }
            } else if session.client.cachedContentDownloadingAllowed == true {
                Menu {
                    ForEach(downloadQualities) { quality in
                        Button(quality.title) {
                            Task {
                                if let failure = await DownloadActions.start(item: item, quality: quality, session: session) {
                                    DownloadStore.log.error("Context menu download failed: \(failure, privacy: .public)")
                                }
                            }
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    /// Default quality first, as in `DownloadControl`. High and Standard need
    /// transcode permission; Original needs only download permission.
    private var downloadQualities: [DownloadQuality] {
        let store = DownloadStore.shared
        let allowed: [DownloadQuality] = session.client.cachedVideoTranscodingAllowed == true
            ? DownloadQuality.allCases
            : [.original]
        guard allowed.contains(store.defaultQuality) else { return allowed }
        return [store.defaultQuality] + allowed.filter { $0 != store.defaultQuality }
    }
    #endif

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

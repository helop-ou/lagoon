import Observation
import SwiftUI

@Observable
final class CollectionDetailViewModel {
    var detail: MediaItem?
    var items: [MediaItem] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: JellyfinClient, collection: MediaItem) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        // The list's own record adds overview and artwork. Its failure
        // never fails the page.
        async let detailTask = try? await client.item(id: collection.id)
        do {
            items = try await contents(of: collection, client: client)
        } catch {
            errorMessage = collection.type == .playlist
                ? String(localized: "Couldn't load this playlist.")
                : String(localized: "Couldn't load this collection.")
        }
        if let refreshedDetail = await detailTask {
            detail = refreshedDetail
        }
        isLoading = false
    }

    /// After a poster-menu toggle or playback only the titles can have
    /// moved.
    func refreshItems(client: JellyfinClient, collection: MediaItem) async {
        guard let refreshed = try? await contents(of: collection, client: client) else { return }
        items = refreshed
    }

    /// A playlist in the order its owner arranged it. A collection in the
    /// order it is set to.
    private func contents(of list: MediaItem, client: JellyfinClient) async throws -> [MediaItem] {
        if list.type == .playlist {
            return try await client.playlistItems(playlistId: list.id)
        }
        return try await client.collectionItems(
            collectionId: list.id,
            displayOrder: (detail ?? list).displayOrder
        )
    }
}

/// One grid cell. Keyed by position, because a playlist can list a title
/// twice under the same ids.
private struct ListEntry: Identifiable {
    let id: Int
    let media: MediaItem
}

/// A collection's or playlist's page, in the list's own order. Play runs the
/// whole list as a queue. A poster in the grid opens just that title.
struct CollectionDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @State private var viewModel = CollectionDetailViewModel()
    @State private var playerItem: PlayerItem?
    #if os(tvOS)
    /// tvOS left focus on the tab bar after the player closed from this
    /// page, where the shared reset does not reach the actions. The film
    /// page does not need it. Claimed back explicitly.
    @FocusState private var actionsFocused: Bool
    #endif

    private var displayed: MediaItem { viewModel.detail ?? item }

    var body: some View {
        DetailPageScaffold(backdropURL: backdropURL) {
            DetailMetadataHeader(
                factTokens: factTokens,
                genres: CollectionShelf.genres(of: displayed, contents: viewModel.items),
                overview: displayed.overview
            ) {
                TitleArtView(item: displayed)
            } buttons: {
                if let playback = ListPlayback(items: viewModel.items, source: source) {
                    actions(playback)
                        #if os(tvOS)
                        .focused($actionsFocused)
                        #endif
                }
            }

            contents
        }
        #if os(iOS)
        .navigationTitle(displayed.name ?? (item.type == .playlist ? "Playlist" : "Collection"))
        // The page draws its own title. A large one inherited from Library or
        // Playlists would repeat it.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: item.id) {
            if viewModel.items.isEmpty {
                await viewModel.load(client: session.client, collection: item)
            }
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await viewModel.load(client: session.client, collection: item) }
        }
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: {
            #if os(tvOS)
            actionsFocused = true
            #endif
            Task {
                // Read progress back only once the stop report has landed.
                await session.client.playbackReports.settle()
                await viewModel.refreshItems(client: session.client, collection: item)
            }
        })
        .accessibilityIdentifier("collection.detail.\(item.id)")
        .accessibilityValue("\(viewModel.items.count) titles")
    }

    @ViewBuilder
    private var contents: some View {
        if viewModel.items.isEmpty, viewModel.isLoading {
            LoadingView()
        } else if viewModel.items.isEmpty {
            // The only focusable element when empty. Without it Menu quits the app.
            InlineRetryView(message: viewModel.errorMessage ?? emptyMessage) {
                Task { await viewModel.load(client: session.client, collection: item) }
            }
            .padding(.horizontal, Metrics.screenGutter)
        } else {
            PosterGridView(items: viewModel.items.enumerated().map(ListEntry.init)) { entry in
                PosterCard(item: entry.media)
                    .itemUserDataMenu(item: entry.media) {
                        await viewModel.refreshItems(client: session.client, collection: item)
                    }
            }
            .padding(.horizontal, Metrics.screenGutter)
        }
    }

    /// Recorded with the queue, so Home can continue the list on any device.
    private var source: QueueSource {
        let isPlaylist = item.type == .playlist
        return QueueSource(
            id: item.id,
            kind: isPlaylist ? .playlist : .collection,
            name: displayed.name ?? "",
            displayOrder: isPlaylist ? nil : displayed.displayOrder
        )
    }

    private var emptyMessage: String {
        item.type == .playlist
            ? String(localized: "There's nothing in this playlist.")
            : String(localized: "There's nothing in this collection.")
    }

    private func actions(_ playback: ListPlayback) -> some View {
        DetailPlayActions(
            resumes: playback.resumes,
            caption: playback.caption,
            play: { playerItem = PlayerItem(list: playback.queue) },
            playFromBeginning: playback.fromBeginning.map { list in
                { playerItem = PlayerItem(list: list, startFromBeginning: true) }
            }
        ) {
            EmptyView()
        }
    }

    /// Falls back to the first title's backdrop. Most collections have none.
    private var backdropURL: URL? {
        let source = displayed.backdropImageTags?.isEmpty == false
            ? displayed
            : viewModel.items.first { $0.backdropImageTags?.isEmpty == false }
        return source.flatMap {
            session.client.imageURL(for: $0, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth)
        }
    }

    /// Counted from the contents. The collection record carries neither.
    private var factTokens: [String] {
        var parts: [String] = []
        if !viewModel.items.isEmpty {
            parts.append(CollectionShelf.countLabel(viewModel.items.count))
        }
        if let years = CollectionShelf.yearsLabel(viewModel.items) {
            parts.append(years)
        }
        return parts
    }
}

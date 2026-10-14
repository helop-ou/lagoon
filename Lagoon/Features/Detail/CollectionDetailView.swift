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
        // The collection's own record adds overview and artwork; its
        // failure never fails the page.
        async let detailTask = try? await client.item(id: collection.id)
        do {
            items = try await client.collectionItems(
                collectionId: collection.id,
                displayOrder: (detail ?? collection).displayOrder
            )
        } catch {
            errorMessage = "Couldn't load this collection."
        }
        if let refreshedDetail = await detailTask {
            detail = refreshedDetail
        }
        isLoading = false
    }

    /// After a poster-menu toggle or playback only the titles can have
    /// moved.
    func refreshItems(client: JellyfinClient, collection: MediaItem) async {
        guard let refreshed = try? await client.collectionItems(
            collectionId: collection.id,
            displayOrder: (detail ?? collection).displayOrder
        ) else { return }
        items = refreshed
    }
}

/// A collection's page, in the collection's own order. Play runs the whole
/// collection as a queue; a poster in the grid opens just that title.
struct CollectionDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @State private var viewModel = CollectionDetailViewModel()
    @State private var playerItem: PlayerItem?
    #if os(tvOS)
    /// tvOS left focus on the tab bar after the player closed from this
    /// page, where the shared reset does not reach the actions; the film
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
                if let playback = CollectionPlayback(items: viewModel.items) {
                    actions(playback)
                        #if os(tvOS)
                        .focused($actionsFocused)
                        #endif
                }
            }

            contents
        }
        #if os(iOS)
        .navigationTitle(displayed.name ?? "Collection")
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
            // The only focusable element when empty; without it Menu quits the app.
            InlineRetryView(message: viewModel.errorMessage ?? "There's nothing in this collection.") {
                Task { await viewModel.load(client: session.client, collection: item) }
            }
            .padding(.horizontal, Metrics.screenGutter)
        } else {
            PosterGridView(items: viewModel.items) { title in
                PosterCard(item: title)
                    .itemUserDataMenu(item: title) {
                        await viewModel.refreshItems(client: session.client, collection: item)
                    }
            }
            .padding(.horizontal, Metrics.screenGutter)
        }
    }

    private func actions(_ playback: CollectionPlayback) -> some View {
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

    /// Falls back to the first title's backdrop; most collections have none.
    private var backdropURL: URL? {
        let source = displayed.backdropImageTags?.isEmpty == false
            ? displayed
            : viewModel.items.first { $0.backdropImageTags?.isEmpty == false }
        return source.flatMap {
            session.client.imageURL(for: $0, kind: .backdrop, maxWidth: Metrics.detailBackdropRequestWidth)
        }
    }

    /// Counted from the contents; the collection record carries neither.
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

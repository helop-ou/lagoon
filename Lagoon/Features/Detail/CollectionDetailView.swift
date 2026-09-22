import Observation
import SwiftUI

@Observable
final class CollectionDetailViewModel {
    var detail: MediaItem?
    var items: [MediaItem] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: JellyfinClient, collectionId: String) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        // The collection's own record adds overview and artwork; its
        // failure never fails the page.
        async let detailTask = try? await client.item(id: collectionId)
        do {
            items = try await client.collectionItems(collectionId: collectionId)
        } catch {
            errorMessage = "Couldn't load this collection."
        }
        if let refreshedDetail = await detailTask {
            detail = refreshedDetail
        }
        isLoading = false
    }

    /// After a poster-menu toggle only the grid can have moved.
    func refreshItems(client: JellyfinClient, collectionId: String) async {
        guard let refreshed = try? await client.collectionItems(collectionId: collectionId) else { return }
        items = refreshed
    }
}

/// A collection's page, in release order. No Play button on purpose:
/// "play a franchise" is ambiguous, and the grid answers it in one press.
struct CollectionDetailView: View {
    let item: MediaItem

    @Environment(SessionStore.self) private var session
    @Environment(ServerSyncState.self) private var serverSync
    @State private var viewModel = CollectionDetailViewModel()

    private var displayed: MediaItem { viewModel.detail ?? item }

    let posterLayout = PosterLayout()
    @State private var gridWidth: CGFloat = 0
    private var grid: PosterGrid { posterLayout.grid(fitting: gridWidth) }

    var body: some View {
        DetailPageScaffold(backdropURL: backdropURL) {
            DetailMetadataHeader(
                factTokens: factTokens,
                genres: CollectionShelf.genres(of: displayed, contents: viewModel.items),
                overview: displayed.overview
            ) {
                TitleArtView(item: displayed)
            } buttons: {
                EmptyView()
            }

            contents
        }
        #if os(iOS)
        .navigationTitle(displayed.name ?? "Collection")
        #endif
        .task(id: item.id) {
            if viewModel.items.isEmpty {
                await viewModel.load(client: session.client, collectionId: item.id)
            }
        }
        .onChange(of: serverSync.generation) { _, _ in
            Task { await viewModel.load(client: session.client, collectionId: item.id) }
        }
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
                Task { await viewModel.load(client: session.client, collectionId: item.id) }
            }
            .padding(.horizontal, Metrics.screenGutter)
        } else {
            LazyVGrid(columns: grid.columns, spacing: Metrics.gridRowSpacing) {
                ForEach(viewModel.items) { title in
                    PosterCard(item: title)
                        .itemUserDataMenu(item: title) {
                            await viewModel.refreshItems(client: session.client, collectionId: item.id)
                        }
                }
            }
            .environment(\.posterCardWidth, grid.cardWidth)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
            .padding(.horizontal, Metrics.screenGutter)
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

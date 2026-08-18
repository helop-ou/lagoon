import SwiftUI
import Observation

@Observable
final class LibraryViewModel {
    var items: [MediaItem] = []
    var isLoading = false
    var errorMessage: String?

    private var totalCount: Int?
    private let pageSize = 60

    var hasMore: Bool {
        totalCount.map { items.count < $0 } ?? true
    }

    func loadMore(client: JellyfinClient, library: MediaItem) async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        do {
            let page = try await client.items(
                parentId: library.id,
                includeTypes: library.collectionType == "tvshows" ? [.series] : [.movie],
                startIndex: items.count,
                limit: pageSize
            )
            items.append(contentsOf: page.items)
            totalCount = page.totalRecordCount
        } catch {
            errorMessage = "Couldn't load this library."
        }
        isLoading = false
    }
}

struct LibraryView: View {
    let library: MediaItem
    @Environment(SessionStore.self) private var session
    @State private var viewModel = LibraryViewModel()

    private var columns: [GridItem] { Metrics.posterGridColumns }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if viewModel.items.isEmpty, viewModel.isLoading {
                LoadingView()
            } else if viewModel.items.isEmpty, let errorMessage = viewModel.errorMessage {
                ErrorStateView(message: errorMessage) {
                    Task { await viewModel.loadMore(client: session.client, library: library) }
                }
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                            PosterCard(item: item)
                                .itemUserDataMenu(item: item)
                                .onAppear {
                                    if index >= viewModel.items.count - Metrics.gridColumns * 3 {
                                        Task { await viewModel.loadMore(client: session.client, library: library) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                }
                .scrollClipDisabled()
            }
        }
        #if os(iOS)
        .navigationTitle(library.name ?? "Library")
        #endif
        .task(id: library.id) {
            if viewModel.items.isEmpty {
                await viewModel.loadMore(client: session.client, library: library)
            }
        }
    }
}

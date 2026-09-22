import Observation
import SwiftUI

nonisolated enum SearchResultSource {
    case library, seerr
    var title: String { self == .library ? "In Your Library" : "From Seerr" }
}

nonisolated enum SearchResultItem: Identifiable {
    case library(MediaItem)
    case seerr(SeerrDiscoverResult)

    var id: String {
        switch self {
        case .library(let item): "library:\(item.id)"
        case .seerr(let item): "seerr:\(item.mediaType?.rawValue ?? "unknown"):\(item.id)"
        }
    }
}

nonisolated struct SearchResultsPage {
    let items: [SearchResultItem]
    let nextOffset: Int?

    static func library(_ page: ItemsPage, offset: Int, limit: Int) -> Self {
        let next = offset + page.items.count
        let hasMore = !page.items.isEmpty
            && (page.totalRecordCount.map { next < $0 } ?? (page.items.count == limit))
        return Self(items: SearchViewModel.presentable(page.items).map(SearchResultItem.library),
                    nextOffset: hasMore ? next : nil)
    }

    static func seerr(_ page: SeerrDiscoverPage) -> Self {
        Self(items: page.results.filter { $0.mediaType == .movie || $0.mediaType == .tv }
            .map(SearchResultItem.seerr),
             nextOffset: page.page < page.totalPages ? page.page : nil)
    }
}

@Observable
final class SearchResultsViewModel {
    private(set) var items: [SearchResultItem] = []
    private(set) var nextOffset: Int? = 0
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    /// Rewinds the cursor so a retry re-runs the search from the start.
    func restart() {
        items = []
        nextOffset = 0
        errorMessage = nil
    }

    /// The cursor counts raw server results, not the filtered or deduplicated
    /// cards. A page of people or empty collections must not skip later hits.
    func loadNext(fetch: (Int) async throws -> SearchResultsPage) async {
        guard !isLoading, let offset = nextOffset else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let page = try await fetch(offset)
            try Task.checkCancellation()
            var seen = Set(items.map(\.id))
            items += page.items.filter { seen.insert($0.id).inserted }
            nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
        } catch is CancellationError {
            // Keep the cursor so returning to this view can retry the page.
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Couldn't load search results."
        }
    }
}

struct SearchResultsView: View {
    let query: String
    let source: SearchResultSource
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var model = SearchResultsViewModel()
    @State private var loadID = 0
    private let layout = PosterLayout()
    @State private var gridWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Space.xl) {
                Text(query).font(.title.bold()).accessibilityAddTraits(.isHeader)
                let grid = layout.grid(fitting: gridWidth)
                LazyVGrid(columns: grid.columns, spacing: Metrics.gridRowSpacing) {
                    ForEach(model.items) { item in
                        Group {
                            switch item {
                            case .library(let item): PosterCard(item: item)
                            case .seerr(let item): SeerrMediaCard(item: item)
                            }
                        }
                    }
                }
                .environment(\.posterCardWidth, grid.cardWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                if model.isLoading, model.items.isEmpty {
                    // Focusable, unlike a bare spinner: with nothing to focus,
                    // Menu quits the app.
                    LoadingView()
                } else if model.isLoading {
                    ProgressView("Loading Results")
                        .frame(maxWidth: .infinity)
                } else if let error = model.errorMessage {
                    InlineRetryView(message: error) { loadID += 1 }
                } else if model.nextOffset != nil {
                    Button("Load More Results") { loadID += 1 }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("search.results.more")
                } else if model.items.isEmpty {
                    // The only focusable element when empty; without it Menu
                    // quits the app. The cursor is spent, so retry rewinds it.
                    InlineRetryView(message: "No matching movies or shows.") {
                        model.restart()
                        loadID += 1
                    }
                    .accessibilityIdentifier("search.results.empty")
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.vertical, Metrics.Space.xl)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(source.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: loadID) {
            await model.loadNext { offset in
                switch source {
                case .library:
                    let page = try await session.client.items(
                        includeTypes: [.movie, .series, .boxSet], searchTerm: query,
                        startIndex: offset, limit: 60
                    )
                    return .library(page, offset: offset, limit: 60)
                case .seerr:
                    return .seerr(try await seerr.client.search(query: query, page: offset + 1))
                }
            }
        }
        .accessibilityIdentifier("search.results")
        .accessibilityValue("\(model.items.count) results")
    }
}

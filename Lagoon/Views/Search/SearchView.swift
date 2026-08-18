import SwiftUI
import Observation

@Observable
final class SearchViewModel {
    var results: [MediaItem] = []
    var isSearching = false
    var hasSearched = false

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(_ query: String, client: JellyfinClient) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            isSearching = true
            let page = try? await client.items(
                includeTypes: [.movie, .series],
                searchTerm: trimmed,
                limit: 60
            )
            guard !Task.isCancelled else { return }
            results = page?.items ?? []
            hasSearched = true
            isSearching = false
        }
    }
}

struct SearchView: View {
    @Environment(SessionStore.self) private var session
    @State private var viewModel = SearchViewModel()
    @State private var query = ""

    private var columns: [GridItem] { Metrics.posterGridColumns }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                if viewModel.results.isEmpty {
                    emptyState
                        .padding(.top, Metrics.Space.section * 2)
                } else {
                    LazyVGrid(columns: columns, spacing: Metrics.gridRowSpacing) {
                        ForEach(viewModel.results) { item in
                            PosterCard(item: item)
                                .itemUserDataMenu(item: item)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                }
            }
            .scrollClipDisabled()
        }
        // Scoped to the content, not the NavigationStack — otherwise the
        // search field stays overlaid on pushed detail pages.
        .searchable(text: $query, prompt: "Movies and shows")
        .onChange(of: query) { _, newValue in
            viewModel.search(newValue, client: session.client)
        }
        .animation(.easeInOut(duration: Motion.standard), value: viewModel.results.isEmpty)
    }

    private var emptyState: some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: viewModel.hasSearched ? "questionmark.circle" : "magnifyingglass")
                .font(Typography.largeGlyph)
                .foregroundStyle(.tertiary)
            Text(viewModel.hasSearched ? "No results" : "Search your library")
                .font(.title3.bold())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

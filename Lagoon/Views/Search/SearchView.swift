import SwiftUI
import Observation

@Observable
final class SearchViewModel {
    var results: [MediaItem] = []
    var isSearching = false
    var hasSearched = false
    var errorMessage: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(_ query: String, client: JellyfinClient) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        errorMessage = nil
        guard !trimmed.isEmpty else {
            results = []
            hasSearched = false
            isSearching = false
            return
        }
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                isSearching = true
                let page = try await client.items(
                    includeTypes: [.movie, .series],
                    searchTerm: trimmed,
                    limit: 60
                )
                try Task.checkCancellation()
                results = page.items
                hasSearched = true
                isSearching = false
            } catch is CancellationError {
                // A newer query owns all visible state.
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                hasSearched = true
                isSearching = false
                errorMessage = "Couldn't search your library."
            }
        }
    }

    #if DEBUG
    func loadNavigationRegressionResults(client: JellyfinClient) async {
        guard results.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        do {
            let page = try await client.items(includeTypes: [.movie, .series], limit: 60)
            try Task.checkCancellation()
            results = page.items
            hasSearched = true
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn't load navigation regression content."
        }
        isSearching = false
    }
    #endif
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
                if let errorMessage = viewModel.errorMessage {
                    ErrorStateView(message: errorMessage) {
                        viewModel.search(query, client: session.client)
                    }
                    .padding(.top, Metrics.Space.section * 2)
                } else if viewModel.results.isEmpty {
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
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "debug.navigationRegression") {
                await viewModel.loadNavigationRegressionResults(client: session.client)
            }
        }
        #endif
        .animation(.easeInOut(duration: Motion.standard), value: viewModel.results.isEmpty)
        .accessibilityIdentifier("search.view")
        .accessibilityValue("\(viewModel.results.count) items")
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

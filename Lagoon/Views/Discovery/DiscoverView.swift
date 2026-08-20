import SwiftUI
import Observation

@Observable
private final class DiscoverViewModel {
    var trending: [SeerrDiscoverResult] = []
    var movies: [SeerrDiscoverResult] = []
    var shows: [SeerrDiscoverResult] = []
    var upcoming: [SeerrDiscoverResult] = []
    var isLoading = false
    var errorMessage: String?

    func load(client: SeerrClient) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            async let trendingPage = client.trending()
            async let moviePage = client.discover(.movie)
            async let showPage = client.discover(.tv)
            async let upcomingPage = client.upcomingMovies()
            let pages = try await (trendingPage, moviePage, showPage, upcomingPage)
            guard !Task.isCancelled else { return }
            trending = pages.0.results
            movies = pages.1.results
            shows = pages.2.results
            upcoming = pages.3.results
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiscoverView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = DiscoverViewModel()
    @State private var librarySearch = SearchViewModel()
    @State private var searchText = ""
    @State private var searchResults: [SeerrDiscoverResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var reloadID = 0
    @State private var searchRetryID = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                pageHeader

                // Library search remains useful when Seerr is disconnected
                // or still restoring its cookie, so a query always wins over
                // the connection state below.
                if !normalizedSearch.isEmpty {
                    searchSections
                } else if seerr.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if !seerr.isConnected {
                    connectionState
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else if viewModel.isLoading, viewModel.trending.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                        .accessibilityLabel("Loading Discover")
                } else if let error = viewModel.errorMessage, viewModel.trending.isEmpty {
                    ErrorStateView(message: error) { reloadID += 1 }
                        .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
                } else {
                    discoverySections
                }
            }
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
        .searchable(text: $searchText, prompt: "Search your library and Seerr")
        .refreshable {
            guard seerr.isConnected, normalizedSearch.isEmpty else { return }
            await viewModel.load(client: seerr.client)
        }
        .onChange(of: searchText) { _, newValue in
            librarySearch.search(newValue, client: session.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(reloadID)") {
            guard seerr.isConnected else { return }
            await viewModel.load(client: seerr.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(normalizedSearch):\(searchRetryID)") {
            await performSearch()
        }
        .accessibilityIdentifier("seerr.discover")
        .accessibilityValue("\(librarySearch.results.count) library, \(searchResults.count) Seerr results")
    }

    private var connectionState: some View {
        VStack(spacing: Metrics.Space.l) {
            Image(systemName: "sparkles.tv")
                .font(Typography.largeGlyph)
                .foregroundStyle(.secondary)
            Text(seerr.isConfigured ? "Sign In to Seerr" : "Connect Seerr")
                .font(.title3.bold())
            Text(seerr.isConfigured
                 ? "Connect this Jellyfin user to browse and manage requests."
                 : "Add your Seerr server to browse movies and shows outside your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 700)
            NavigationLink(value: SeerrNavigationRoute.settings) {
                Text(seerr.isConfigured ? "Sign In" : "Set Up Seerr")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.setup")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var discoverySections: some View {
        HStack(spacing: Metrics.Space.m) {
            NavigationLink(value: SeerrNavigationRoute.catalog(.movie)) {
                Label("Movies", systemImage: "film")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.catalog.movies")

            NavigationLink(value: SeerrNavigationRoute.catalog(.tv)) {
                Label("Shows", systemImage: "tv")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.catalog.shows")

            NavigationLink(value: SeerrNavigationRoute.requests) {
                Label(requestsTitle, systemImage: "tray.full")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("seerr.requests")
        }
        .padding(.horizontal, Metrics.screenGutter)
        .padding(.bottom, Metrics.Space.xl)

        SeerrMediaRail(title: "Trending", items: viewModel.trending)
        SeerrMediaRail(title: "Popular Movies", items: viewModel.movies)
        SeerrMediaRail(title: "Popular Shows", items: viewModel.shows)
        SeerrMediaRail(title: "Upcoming Movies", items: viewModel.upcoming)
    }

    @ViewBuilder
    private var searchSections: some View {
        librarySearchSection
        seerrSearchSection
    }

    @ViewBuilder
    private var librarySearchSection: some View {
        if !librarySearch.results.isEmpty {
            MediaRail(title: "In Your Library", items: librarySearch.results)
        } else {
            searchStatusSection(
                title: "In Your Library",
                isLoading: librarySearch.isSearching,
                message: librarySearch.errorMessage ?? "No matching movies or shows in your library.",
                canRetry: librarySearch.errorMessage != nil
            ) {
                librarySearch.search(searchText, client: session.client)
            }
        }
    }

    @ViewBuilder
    private var seerrSearchSection: some View {
        if !seerr.isConnected {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                Text("From Seerr")
                    .font(.headline)
                Text(seerr.isLoading
                     ? "Connecting to Seerr…"
                     : "Connect Seerr to find titles outside your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if !seerr.isLoading {
                    NavigationLink(value: SeerrNavigationRoute.settings) {
                        Text(seerr.isConfigured ? "Sign In to Seerr" : "Set Up Seerr")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
        } else if !requestableSearchResults.isEmpty {
            SeerrMediaRail(title: "From Seerr", items: requestableSearchResults)
        } else {
            searchStatusSection(
                title: "From Seerr",
                isLoading: isSearching,
                message: searchError ?? "No matching movies or shows on Seerr.",
                canRetry: searchError != nil
            ) {
                searchRetryID += 1
            }
        }
    }

    private func searchStatusSection(
        title: String,
        isLoading: Bool,
        message: String,
        canRetry: Bool,
        retry: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            Text(title)
                .font(.headline)
            if isLoading {
                ProgressView()
            } else {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if canRetry {
                    Button("Try Again", action: retry)
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(.horizontal, Metrics.screenGutter)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    private var pageHeader: some View {
        Text("Discover")
            .font(.largeTitle.bold())
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.Space.xxl)
            .padding(.bottom, Metrics.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requestsTitle: String {
        seerr.user?.canViewAllRequests == true ? "All Requests" : "My Requests"
    }

    private var requestableSearchResults: [SeerrDiscoverResult] {
        searchResults.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }

    private func performSearch() async {
        let term = normalizedSearch
        guard !term.isEmpty else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        guard seerr.isConnected else {
            searchResults = []
            searchError = nil
            isSearching = false
            return
        }
        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            let page = try await seerr.client.search(query: term)
            guard !Task.isCancelled, normalizedSearch == term else { return }
            searchResults = page.results
        } catch is CancellationError {
        } catch {
            guard normalizedSearch == term else { return }
            searchError = error.localizedDescription
            searchResults = []
        }
        if normalizedSearch == term { isSearching = false }
    }
}

@Observable
private final class SeerrCatalogViewModel {
    var items: [SeerrDiscoverResult] = []
    var page = 0
    var totalPages = 1
    var isLoading = false
    var errorMessage: String?

    func loadNext(mediaType: SeerrMediaType, client: SeerrClient, reset: Bool = false) async {
        guard !isLoading else { return }
        if reset {
            items = []
            page = 0
            totalPages = 1
        }
        guard page < totalPages else { return }
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let result = try await client.discover(mediaType, page: page + 1)
            guard !Task.isCancelled else { return }
            let existing = Set(items.map(\.id))
            items += result.results.filter { !existing.contains($0.id) }
            page = result.page
            totalPages = result.totalPages
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct SeerrCatalogView: View {
    let mediaType: SeerrMediaType
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var viewModel = SeerrCatalogViewModel()

    var body: some View {
        Group {
            if viewModel.isLoading, viewModel.items.isEmpty {
                LoadingView()
            } else if let error = viewModel.errorMessage, viewModel.items.isEmpty {
                ErrorStateView(message: error) {
                    Task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client, reset: true) }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: Metrics.Space.xxl) {
                        ForEach(viewModel.items) { item in
                            SeerrMediaCard(item: item)
                                .onAppear {
                                    guard item.id == viewModel.items.suffix(5).first?.id else { return }
                                    Task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client) }
                                }
                        }
                        if viewModel.isLoading {
                            ProgressView().frame(width: Metrics.posterWidth, height: Metrics.posterHeight)
                        }
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.vertical, Metrics.Space.xxl)
                }
                .scrollClipDisabled()
            }
        }
        .navigationTitle(mediaType == .movie ? "Discover Movies" : "Discover Shows")
        .task { await viewModel.loadNext(mediaType: mediaType, client: seerr.client) }
        .accessibilityIdentifier("seerr.catalog.\(mediaType.rawValue)")
    }

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.fixed(Metrics.posterWidth), spacing: Metrics.cardSpacing), count: Metrics.gridColumns)
    }
}

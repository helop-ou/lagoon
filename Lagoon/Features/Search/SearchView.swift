import SwiftUI
import Observation

@Observable
final class SearchViewModel {
    var results: [MediaItem] = []
    var isSearching = false
    var errorMessage: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var currentQuery = ""

    func search(_ query: String, client: JellyfinClient) {
        let identity = client.sessionIdentity
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
        if trimmed != currentQuery { results = [] }
        currentQuery = trimmed
        guard !trimmed.isEmpty else {
            results = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(400))
                try Task.checkCancellation()
                guard identity == client.sessionIdentity else { throw CancellationError() }
                let page = try await client.items(
                    includeTypes: [.movie, .series, .boxSet],
                    searchTerm: trimmed,
                    limit: 60
                )
                try Task.checkCancellation()
                results = Self.presentable(page.items)
                isSearching = false
            } catch is CancellationError {
                // A newer query owns all visible state.
            } catch {
                guard !Task.isCancelled else { return }
                results = []
                isSearching = false
                errorMessage = "Couldn't search your library."
            }
        }
    }

    /// Drops near-empty collection stubs, which would otherwise top franchise
    /// searches. The same floor Home's row uses.
    nonisolated static func presentable(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { $0.type != .boxSet || ($0.childCount ?? 0) >= CollectionShelf.minimumTitles }
    }

    #if DEBUG
    /// Results for the regression harness without typing, which XCUITest
    /// does one glyph at a time.
    func loadNavigationRegressionResults(client: JellyfinClient) async {
        guard results.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        do {
            let page = try await client.items(includeTypes: [.movie, .series], limit: 60)
            try Task.checkCancellation()
            results = page.items
        } catch is CancellationError {
        } catch {
            errorMessage = "Couldn't load navigation regression content."
        }
        isSearching = false
    }
    #endif
}

/// Past search terms, per account, since typing on tvOS is slow.
@Observable
final class RecentSearchStore {
    private(set) var terms: [String] = []
    private(set) var accountID: String?

    static let limit = 10

    private let defaults: UserDefaults
    private var key: String? { accountID.map { "search.recents.\($0)" } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Legacy history has no owner; never hand it to whoever launches first.
        defaults.removeObject(forKey: "search.recents")
    }

    func configure(accountID: String?) {
        self.accountID = accountID
        terms = Self.decode(key.flatMap { defaults.data(forKey: $0) })
    }

    /// Records a term that ran, most recent first, folding case and padding.
    /// Drops the prefixes it was typed through ("d", "du", "dun"): remote
    /// key presses are slower than any useful debounce, so each one ran.
    func record(_ term: String) {
        guard accountID != nil else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = terms.filter {
            !$0.matchesSearchTerm(trimmed) && !$0.isSearchPrefix(of: trimmed)
        }
        updated.insert(trimmed, at: 0)
        terms = Array(updated.prefix(Self.limit))
        persist()
    }

    func clear() {
        terms = []
        persist()
    }

    private func persist() {
        guard let key else { return }
        defaults.set(try? JSONEncoder().encode(terms), forKey: key)
    }

    private static func decode(_ data: Data?) -> [String] {
        guard let data, let stored = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Array(stored.prefix(limit))
    }
}

extension String {
    func matchesSearchTerm(_ other: String) -> Bool {
        let lhs = trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// "du" against "dune", folded like `matchesSearchTerm`. One-directional:
    /// recording "the" must not evict "the matrix".
    func isSearchPrefix(of other: String) -> Bool {
        let lhs = trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, lhs.count < rhs.count else { return false }
        return rhs.range(
            of: lhs,
            options: [.caseInsensitive, .diacriticInsensitive, .anchored]
        ) != nil
    }
}

/// A tab of its own: on tvOS `.searchable` draws a full keyboard and owns
/// the screen.
struct SearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @Environment(ServerSyncState.self) private var serverSync
    @State private var librarySearch = SearchViewModel()
    private var recents: RecentSearchStore { session.recentSearches }
    @State private var searchText = ""
    @State private var searchResults: [SeerrDiscoverResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchRetryID = 0

    /// Before a term runs against Seerr and is remembered.
    private static let debounceMilliseconds = 350

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if normalizedSearch.isEmpty, librarySearch.results.isEmpty {
                    recentSearches
                } else {
                    librarySearchSection
                    seerrSearchSection
                }
            }
            .padding(.bottom, Metrics.Space.section)
        }
        .scrollClipDisabled()
        .background(Theme.background.ignoresSafeArea())
        // On the content, never the NavigationStack, or the field overlays
        // pushed detail pages.
        .searchable(text: $searchText, prompt: "Search your library and Seerr")
        .onChange(of: searchText) { _, newValue in
            librarySearch.search(newValue, client: session.client)
        }
        .onChange(of: serverSync.generation) { _, _ in
            // Only the Jellyfin half: Seerr stays out of Jellyfin's
            // foreground sync.
            librarySearch.search(searchText, client: session.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(normalizedSearch):\(searchRetryID)") {
            await performSearch()
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "debug.navigationRegression") {
                await librarySearch.loadNavigationRegressionResults(client: session.client)
            }
            // `-debug.searchRegressionQuery <term>` seeds the field for the
            // empty-results lane; the real search and debounce still run.
            if let seeded = UserDefaults.standard.string(forKey: "debug.searchRegressionQuery"),
               !seeded.isEmpty, searchText.isEmpty {
                searchText = seeded
            }
        }
        #endif
        .accessibilityIdentifier("search.view")
        .accessibilityValue("\(librarySearch.results.count) library, \(searchResults.count) Seerr results")
    }

    @ViewBuilder
    private var recentSearches: some View {
        if recents.terms.isEmpty {
            VStack(spacing: Metrics.Space.l) {
                Image(systemName: "magnifyingglass")
                    .font(Typography.largeGlyph)
                    .foregroundStyle(.tertiary)
                Text("Recent searches will appear here")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
        } else {
            // MediaRail's shape and focus-lift headroom, over terms.
            VStack(alignment: .leading, spacing: 0) {
                Text("Recent")
                    .font(.headline)
                    .padding(.leading, Metrics.screenGutter)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Metrics.Space.m) {
                        ForEach(recents.terms, id: \.self) { term in
                            Button(term) { searchText = term }
                                .buttonStyle(.glass)
                                .accessibilityIdentifier("search.recent")
                        }
                        // The HIG asks for a way to clear search history.
                        Button("Clear", systemImage: "trash") { recents.clear() }
                            .buttonStyle(.glass)
                            .accessibilityIdentifier("search.recent.clear")
                    }
                    .padding(.horizontal, Metrics.screenGutter)
                    .padding(.top, Metrics.railTopPadding)
                    .padding(.bottom, Metrics.railBottomPadding)
                }
            }
            .padding(.top, Metrics.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var librarySearchSection: some View {
        if !librarySearch.results.isEmpty {
            MediaRail(title: "In Your Library", items: librarySearch.results,
                      destination: normalizedSearch.isEmpty ? nil : .search(normalizedSearch))
        } else {
            searchStatusSection(
                title: "In Your Library",
                isLoading: librarySearch.isSearching,
                message: librarySearch.errorMessage ?? "No matching movies or shows in your library.",
                canRetry: librarySearch.errorMessage != nil
            ) {
                librarySearch.search(searchText, client: session.client)
            }
            // No "See All" beside an empty section: the page behind it is
            // empty too, has nothing to focus, and Menu would quit the app.
            // The status block stays unfocusable so Down from the field
            // reaches the Seerr section.
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
                    .accessibilityIdentifier("search.seerr.setup")
                }
            }
            .padding(.horizontal, Metrics.screenGutter)
        } else if !requestableSearchResults.isEmpty {
            SeerrMediaRail(title: "From Seerr", items: requestableSearchResults,
                           destination: .search(normalizedSearch))
        } else {
            searchStatusSection(
                title: "From Seerr",
                isLoading: isSearching,
                message: searchError ?? "No matching movies or shows on Seerr.",
                canRetry: searchError != nil
            ) {
                searchRetryID += 1
            }
            // No "See All" when empty, as in the library section.
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
                    .accessibilityLabel("Searching \(title)")
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

    private var normalizedSearch: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var requestableSearchResults: [SeerrDiscoverResult] {
        searchResults.filter { $0.mediaType == .movie || $0.mediaType == .tv }
    }

    private func performSearch() async {
        let accountID = session.activeAccount?.id
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
            // The library half ran, so record the term after the same debounce.
            try? await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard !Task.isCancelled, normalizedSearch == term, accountID == session.activeAccount?.id else { return }
            recents.record(term)
            return
        }
        isSearching = true
        searchError = nil
        searchResults = []
        do {
            try await Task.sleep(for: .milliseconds(Self.debounceMilliseconds))
            guard accountID == session.activeAccount?.id else { throw CancellationError() }
            let page = try await seerr.client.search(query: term)
            guard !Task.isCancelled, normalizedSearch == term, accountID == session.activeAccount?.id else { return }
            searchResults = page.results
            recents.record(term)
        } catch is CancellationError {
        } catch {
            guard normalizedSearch == term else { return }
            searchError = error.localizedDescription
            searchResults = []
        }
        if normalizedSearch == term { isSearching = false }
    }
}

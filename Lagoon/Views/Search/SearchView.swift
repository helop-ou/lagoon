import SwiftUI
import Observation

@Observable
final class SearchViewModel {
    var results: [MediaItem] = []
    var isSearching = false
    var errorMessage: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?

    func search(_ query: String, client: JellyfinClient) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
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

    /// Drops the collections not worth offering (HEL-122).
    ///
    /// Searching a franchise name matches the collection *and* every film in
    /// it, so the stubs a metadata scrape leaves behind would otherwise put a
    /// dead end at the top of the results — a library holds far more empty
    /// collections than real ones. The same floor Home's row uses.
    static func presentable(_ items: [MediaItem]) -> [MediaItem] {
        items.filter { $0.type != .boxSet || ($0.childCount ?? 0) >= CollectionShelf.minimumTitles }
    }

    #if DEBUG
    /// The navigation regression harness needs results without driving the
    /// on-screen keyboard, which XCUITest can only do one glyph at a time.
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

/// Terms people searched before, so the next search is a click rather than a
/// spell-out. The tvOS HIG asks for this directly: "People typically don't
/// want to do a lot of typing in tvOS."
@Observable
final class RecentSearchStore {
    /// One store for the app: the Search screen reads it and account
    /// switching clears it, and both must see the same array rather than
    /// each holding a copy of what the defaults said at init.
    static let shared = RecentSearchStore()

    private(set) var terms: [String] = []

    /// Long enough to cover a viewing session's worth of titles, short enough
    /// that the row stays scannable from the couch.
    static let limit = 10

    private let defaults: UserDefaults
    private static let key = "search.recents"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        terms = Self.decode(defaults.data(forKey: Self.key))
    }

    /// Records a term that actually ran. Most recent first, folded against
    /// case and surrounding space so "Dune" typed twice is one entry.
    func record(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var updated = terms.filter { !$0.matchesSearchTerm(trimmed) }
        updated.insert(trimmed, at: 0)
        terms = Array(updated.prefix(Self.limit))
        persist()
    }

    func clear() {
        terms = []
        persist()
    }

    private func persist() {
        defaults.set(try? JSONEncoder().encode(terms), forKey: Self.key)
    }

    private static func decode(_ data: Data?) -> [String] {
        guard let data, let stored = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Array(stored.prefix(limit))
    }
}

extension String {
    /// Two searches are the same search when only case or padding differ.
    func matchesSearchTerm(_ other: String) -> Bool {
        let lhs = trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }
}

/// The app's one search screen. On tvOS `.searchable` is not a bar you summon:
/// the system draws the field and a full keyboard and expects to own the
/// screen, which is why this is a tab of its own rather than a fixture on
/// Discover (HEL-111).
struct SearchView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr
    @State private var librarySearch = SearchViewModel()
    private let recents = RecentSearchStore.shared
    @State private var searchText = ""
    @State private var searchResults: [SeerrDiscoverResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var searchRetryID = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                // Results win over recents whenever there are any, so the
                // row of past terms is what fills the screen only when
                // nothing has been searched yet.
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
        .background(Color.black.ignoresSafeArea())
        // Scoped to the content, not the NavigationStack — otherwise the
        // search field stays overlaid on pushed detail pages.
        .searchable(text: $searchText, prompt: "Search your library and Seerr")
        .onChange(of: searchText) { _, newValue in
            librarySearch.search(newValue, client: session.client)
        }
        .task(id: "\(seerr.user?.id ?? -1):\(normalizedSearch):\(searchRetryID)") {
            await performSearch()
        }
        #if DEBUG
        .task {
            if UserDefaults.standard.bool(forKey: "debug.navigationRegression") {
                await librarySearch.loadNavigationRegressionResults(client: session.client)
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
                // Not a second copy of the field's own prompt: this space
                // says what will fill it once someone has searched.
                Text("Recent searches will appear here")
                    .font(.title3.bold())
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.heroHeight)
        } else {
            // Built like MediaRail rather than reusing it: the same shelf
            // shape and the same focus-lift headroom, over terms instead of
            // artwork.
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
                        // The HIG asks for a way to clear search history; a
                        // button on the row it clears beats a Settings page
                        // nobody would look in.
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
            // The library half still ran, so the term was still a search.
            recents.record(term)
            return
        }
        isSearching = true
        searchError = nil
        do {
            try await Task.sleep(for: .milliseconds(350))
            let page = try await seerr.client.search(query: term)
            guard !Task.isCancelled, normalizedSearch == term else { return }
            searchResults = page.results
            // Recorded after the debounce survives, so typing "dune" leaves
            // one entry rather than "d", "du", "dun", "dune".
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

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

    /// Drops the collections not worth offering (HEL-122).
    ///
    /// Searching a franchise name matches the collection *and* every film in
    /// it, so the stubs a metadata scrape leaves behind would otherwise put a
    /// dead end at the top of the results — a library holds far more empty
    /// collections than real ones. The same floor Home's row uses.
    nonisolated static func presentable(_ items: [MediaItem]) -> [MediaItem] {
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
    private(set) var terms: [String] = []
    private(set) var accountID: String?

    /// Long enough to cover a viewing session's worth of titles, short enough
    /// that the row stays scannable from the couch.
    static let limit = 10

    private let defaults: UserDefaults
    private var key: String? { accountID.map { "search.recents.\($0)" } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Legacy history has no attributable owner. Never assign it to the
        // next viewer merely because that viewer happens to launch first.
        defaults.removeObject(forKey: "search.recents")
    }

    func configure(accountID: String?) {
        self.accountID = accountID
        terms = Self.decode(key.flatMap { defaults.data(forKey: $0) })
    }

    /// Records a term that actually ran. Most recent first, folded against
    /// case and surrounding space so "Dune" typed twice is one entry.
    ///
    /// The terms it was spelled through go with it. On tvOS a search is
    /// entered a letter at a time against an on-screen keyboard, and every
    /// prefix is a search that genuinely ran, so one "dune" otherwise leaves
    /// "d", "du", "dun" and "dune" sitting in the row. Folding here rather
    /// than leaning on the debounce is what makes it hold: the gap between
    /// two presses on a remote is far longer than any debounce worth having.
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
    /// Two searches are the same search when only case or padding differ.
    func matchesSearchTerm(_ other: String) -> Bool {
        let lhs = trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = other.trimmingCharacters(in: .whitespacesAndNewlines)
        return lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Whether this term is one somebody typed through on the way to
    /// `other` — "du" against "dune" — folded the same way
    /// `matchesSearchTerm` folds it, so "DU" counts as well.
    ///
    /// One-directional on purpose: recording "the" must not evict an earlier
    /// "the matrix", because a short term is a legitimate search of its own.
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

/// The app's one search screen. On tvOS `.searchable` is not a bar you summon:
/// the system draws the field and a full keyboard and expects to own the
/// screen, which is why this is a tab of its own rather than a fixture on
/// Discover (HEL-111).
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

    /// How long a term has to stand still before it counts as a search worth
    /// running against Seerr and worth remembering.
    private static let debounceMilliseconds = 350

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
        .background(Theme.background.ignoresSafeArea())
        // Scoped to the content, not the NavigationStack — otherwise the
        // search field stays overlaid on pushed detail pages.
        .searchable(text: $searchText, prompt: "Search your library and Seerr")
        .onChange(of: searchText) { _, newValue in
            librarySearch.search(newValue, client: session.client)
        }
        .onChange(of: serverSync.generation) { _, _ in
            // An open result list carries user data too; repeat only the
            // Jellyfin half, keeping Seerr's separate session lifecycle out
            // of a Jellyfin foreground sync (HEL-135).
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
            if !librarySearch.isSearching, librarySearch.errorMessage == nil, !normalizedSearch.isEmpty {
                NavigationLink("See All Library Results", value: ContentNavigationRoute.search(normalizedSearch))
                    .buttonStyle(.glass)
                    .padding(.horizontal, Metrics.screenGutter)
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
            if !isSearching, searchError == nil, !normalizedSearch.isEmpty {
                NavigationLink("See All Seerr Results", value: SeerrNavigationRoute.search(normalizedSearch))
                    .buttonStyle(.glass)
                    .padding(.horizontal, Metrics.screenGutter)
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
            // The library half still ran, so the term was still a search --
            // but wait out the same debounce the Seerr path does rather than
            // writing an entry on every keystroke.
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
            // The debounce only keeps this off every keystroke; folding in
            // RecentSearchStore is what makes "dune" one entry rather than
            // "d", "du", "dun", "dune".
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

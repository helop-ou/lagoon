import SwiftUI

struct LibraryView: View {
    let accountID: String
    let libraries: [LibraryTab]
    let librariesLoaded: Bool
    let isActive: Bool
    @Environment(SessionStore.self) private var session
    @State private var selection: LibrarySelection
    @State private var viewModel = LibraryViewModel()
    @State private var decadeViewModel = LibraryDecadeViewModel()
    @State private var decadeRetry = 0
    @State private var genreViewModel = LibraryGenreViewModel()
    @State private var genreRetry = 0

    private struct DecadeRequest: Hashable {
        let scope: LibraryYearScope
        let retry: Int
    }

    init(accountID: String, libraries: [LibraryTab], librariesLoaded: Bool, isActive: Bool) {
        self.accountID = accountID
        self.libraries = libraries
        self.librariesLoaded = librariesLoaded
        self.isActive = isActive
        _selection = State(initialValue: LibrarySelection.restore(accountID: accountID))
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: Metrics.Space.xxl) {
                controls
                results
            }
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.top, Metrics.Space.xxl)
            .padding(.bottom, Metrics.detailBottomPadding)
        }
        .scrollClipDisabled()
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
        .navigationTitle("Library")
        #endif
        .task(id: selection) {
            await viewModel.load(selection: selection, fetch: session.client.libraryItems)
        }
        .task(id: DecadeRequest(scope: selection.yearScope, retry: decadeRetry)) {
            await loadDecades()
        }
        .task(id: genreRetry) {
            await loadGenres()
        }
        .onChange(of: selection) { _, value in
            value.save(accountID: accountID)
        }
        .onChange(of: libraries, initial: true) { _, _ in reconcileSources() }
        .onChange(of: librariesLoaded) { _, _ in reconcileSources() }
        .onChange(of: isActive) { _, active in
            guard active else { return }
            Task {
                await session.client.playbackReports.settle()
                await refreshLibrary()
            }
        }
        .serverRefreshable(.library("all"), isActive: isActive) {
            await refreshLibrary()
        }
        .accessibilityIdentifier("library.view")
        .accessibilityValue("\(viewModel.items.count) items")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            #if os(tvOS)
            HStack(alignment: .firstTextBaseline) {
                Text("Library").font(.largeTitle.bold())
                Spacer()
                resultCount
            }
            HStack(spacing: Metrics.Space.xl) {
                kindPicker
                Spacer(minLength: Metrics.Space.xl)
                sortMenu
                filterMenu
            }
            #else
            kindPicker
            HStack(spacing: Metrics.Space.m) {
                sortMenu
                Spacer(minLength: Metrics.Space.s)
                filterMenu
            }
            resultCount
            #endif
            if selection.filterCount > 0 {
                Text(filterSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("library.filters.summary")
            }
        }
    }

    private var kindPicker: some View {
        Picker("Media Type", selection: Binding(
            get: { selection.kind },
            set: { selection.selectKind($0, libraries: libraries) }
        )) {
            ForEach(LibraryMediaKind.allCases) { kind in
                Text(kind.title).tag(kind)
            }
        }
        #if os(tvOS)
        // Menu choices commit on Select, so moving past this control to
        // Sort or Filters never changes the media type or clears 4K.
        .pickerStyle(.menu)
        .buttonStyle(.glass)
        .accessibilityLabel("Media Type")
        .accessibilityValue(selection.kind.title)
        #else
        .pickerStyle(.segmented)
        #endif
        .accessibilityIdentifier("library.kind")
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $selection.sort) {
                ForEach(LibrarySort.allCases) { sort in
                    Text(sort.title).tag(sort)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(selection.sort.title, systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(.glass)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sort")
        .accessibilityValue(selection.sort.title)
        .accessibilityIdentifier("library.sort")
    }

    private var filterMenu: some View {
        Menu {
            if !selection.kind.libraryChoices(in: libraries).isEmpty {
                Menu("Library") {
                    Picker("Library", selection: $selection.libraryID) {
                        Text("All Libraries").tag(String?.none)
                        ForEach(selection.kind.libraryChoices(in: libraries)) { library in
                            Text(library.name ?? String(localized: "Library")).tag(Optional(library.id))
                        }
                    }
                    .pickerStyle(.inline)
                }
            }
            Menu("Genre") {
                Picker("Genre", selection: $selection.genre) {
                    Text("All Genres").tag(String?.none)
                    // A saved genre stays visible even if the catalogue fails.
                    ForEach(genreNames, id: \.self) { genre in
                        Text(genre).tag(Optional(genre))
                    }
                }
                .pickerStyle(.inline)
                if genreViewModel.isLoading {
                    Button("Loading Genres…") {}.disabled(true)
                } else if genreViewModel.loadFailed || genreViewModel.genres == nil {
                    Button("Retry Loading Genres") { genreRetry += 1 }
                } else if genreNames.isEmpty {
                    Button("No Genres") {}.disabled(true)
                }
            }
            Menu("Decade") {
                Picker("Decade", selection: $selection.decade) {
                    Text("All Decades").tag(LibraryDecade?.none)
                    ForEach(decades) { decade in
                        Text(decade.title).tag(Optional(decade))
                    }
                }
                .pickerStyle(.inline)
                if decadeViewModel.isLoading || decadeViewModel.scope != selection.yearScope {
                    Button("Loading Decades…") {}.disabled(true)
                } else if decadeViewModel.loadFailed || decadeViewModel.decades == nil {
                    Button("Retry Loading Decades") { decadeRetry += 1 }
                } else if decades.isEmpty {
                    Button("No Dated Titles") {}.disabled(true)
                }
            }
            Toggle("Unwatched Only", isOn: $selection.unwatchedOnly)
            Toggle("Favorites Only", isOn: $selection.favoritesOnly)
            if selection.kind == .movies {
                Toggle("4K Only", isOn: $selection.only4K)
            }
            Divider()
            Button("Clear Filters") { selection.clearFilters() }
                .disabled(selection.filterCount == 0)
        } label: {
            Label(
                selection.filterCount == 0
                    ? String(localized: "Filters")
                    : String(localized: "Filters (\(selection.filterCount))"),
                systemImage: "line.3.horizontal.decrease"
            )
        }
        .buttonStyle(.glass)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filters")
        .accessibilityValue("\(selection.filterCount) active")
        .accessibilityIdentifier("library.filters")
    }

    @ViewBuilder private var resultCount: some View {
        if viewModel.hasLoaded, let total = viewModel.totalCount {
            Text("\(total) titles")
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("library.count")
        }
    }

    @ViewBuilder private var results: some View {
        if viewModel.items.isEmpty {
            if let error = viewModel.errorMessage {
                ErrorStateView(message: error) {
                    Task { await viewModel.loadMore(fetch: session.client.libraryItems) }
                }
            } else if viewModel.hasLoaded {
                VStack(spacing: Metrics.Space.l) {
                    ContentUnavailableView(
                        "No Titles", systemImage: "tray",
                        description: Text(selection.filterCount > 0
                            ? "No titles match these filters. Try clearing them or choosing another media type."
                            : "There are no titles to show for this media type.")
                    )
                    if selection.filterCount > 0 {
                        Button("Clear Filters") { selection.clearFilters() }
                            .buttonStyle(.glass)
                    }
                }
                .frame(maxWidth: .infinity)
            } else {
                LoadingView()
            }
        } else {
            LazyVGrid(columns: Metrics.posterGridColumns, spacing: Metrics.gridRowSpacing) {
                ForEach(Array(viewModel.items.enumerated()), id: \.element.id) { index, item in
                    PosterCard(item: item)
                        .itemUserDataMenu(item: item)
                        .onAppear {
                            if index >= viewModel.items.count - Metrics.gridColumns * 3 {
                                Task { await viewModel.loadMore(fetch: session.client.libraryItems) }
                            }
                        }
                }
            }
            if let error = viewModel.errorMessage, !viewModel.isLoading {
                InlineRetryView(message: error) {
                    Task { await viewModel.loadMore(fetch: session.client.libraryItems) }
                }
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Loading more titles")
            }
        }
    }

    private var genreNames: [String] {
        genreViewModel.choices(selected: selection.genre)
    }

    private var decades: [LibraryDecade] {
        decadeViewModel.choices(for: selection.yearScope, selected: selection.decade)
    }

    private var filterSummary: String {
        var parts: [String] = []
        if let id = selection.libraryID {
            parts.append(libraries.first { $0.id == id }?.name ?? String(localized: "Selected Library"))
        }
        if let genre = selection.genre { parts.append(genre) }
        if let decade = selection.decade { parts.append(decade.title) }
        if selection.unwatchedOnly { parts.append(String(localized: "Unwatched")) }
        if selection.favoritesOnly { parts.append(String(localized: "Favorites")) }
        if selection.only4K { parts.append("4K") }
        return parts.joined(separator: " · ")
    }

    private func reconcileSources() {
        guard librariesLoaded else { return }
        selection.reconcile(libraries: libraries)
    }

    private func loadDecades() async {
        let scope = selection.yearScope
        await decadeViewModel.load(scope: scope, fetch: session.client.libraryYears)
        guard !Task.isCancelled, scope == selection.yearScope,
              decadeViewModel.scope == scope, !decadeViewModel.isLoading, !decadeViewModel.loadFailed,
              let available = decadeViewModel.decades else { return }
        selection.reconcileDecade(available: available)
    }

    private func refreshLibrary() async {
        async let years: Void = loadDecades()
        async let genres: Void = loadGenres()
        if viewModel.hasLoaded {
            await viewModel.refresh(fetch: session.client.libraryItems)
        } else {
            await viewModel.load(selection: selection, fetch: session.client.libraryItems)
        }
        _ = await (years, genres)
    }

    private func loadGenres() async {
        await genreViewModel.load { try await session.client.genres() }
    }
}

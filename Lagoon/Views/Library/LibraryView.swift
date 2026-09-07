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
    @State private var genres: [MediaGenre] = []
    @State private var genreLoadFailed = false
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
            do {
                let loaded = try await session.client.genres()
                guard !Task.isCancelled else { return }
                genres = loaded
                genreLoadFailed = false
            } catch {
                guard !Task.isCancelled else { return }
                genreLoadFailed = true
            }
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
        .pickerStyle(.segmented)
        .accessibilityIdentifier("library.kind")
        #if os(tvOS)
        .fixedSize(horizontal: true, vertical: false)
        #endif
    }

    private var sortMenu: some View {
        Menu {
            ForEach(LibrarySort.allCases) { sort in
                Toggle(sort.title, isOn: Binding(
                    get: { selection.sort == sort },
                    set: { if $0 { selection.sort = sort } }
                ))
            }
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
                    Toggle("All Libraries", isOn: sourceBinding(nil))
                    ForEach(selection.kind.libraryChoices(in: libraries)) { library in
                        Toggle(library.name ?? String(localized: "Library"), isOn: sourceBinding(library.id))
                    }
                }
            }
            Menu("Genre") {
                Toggle("All Genres", isOn: genreBinding(nil))
                // A saved genre stays visible even if the catalogue fails.
                ForEach(genreNames, id: \.self) { genre in
                    Toggle(genre, isOn: genreBinding(genre))
                }
                if genreLoadFailed {
                    Button("Retry Loading Genres") { genreRetry += 1 }
                }
            }
            Menu("Decade") {
                Toggle("All Decades", isOn: decadeBinding(nil))
                ForEach(decades) { decade in
                    Toggle(decade.title, isOn: decadeBinding(decade))
                }
                if decadeViewModel.loadFailed {
                    Button("Retry Loading Decades") { decadeRetry += 1 }
                } else if decadeViewModel.isLoading || decadeViewModel.scope != selection.yearScope {
                    Button("Loading Decades…") {}.disabled(true)
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
        Set(genres.map(\.name) + (selection.genre.map { [$0] } ?? []))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
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

    private func sourceBinding(_ id: String?) -> Binding<Bool> {
        Binding(get: { selection.libraryID == id }, set: { if $0 { selection.libraryID = id } })
    }

    private func genreBinding(_ name: String?) -> Binding<Bool> {
        Binding(get: { selection.genre == name }, set: { if $0 { selection.genre = name } })
    }

    private func decadeBinding(_ decade: LibraryDecade?) -> Binding<Bool> {
        Binding(get: { selection.decade == decade }, set: { if $0 { selection.decade = decade } })
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
        if viewModel.hasLoaded {
            await viewModel.refresh(fetch: session.client.libraryItems)
        } else {
            await viewModel.load(selection: selection, fetch: session.client.libraryItems)
        }
        await years
    }
}

import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(DeepLinkRouter.self) private var deepLinks
    @State private var libraries: [LibraryTab] = []
    @State private var playerItem: PlayerItem?
    @State private var deepLinkError: String?
    @State private var deepLinkRetry = 0
    @State private var lifecycleBenchmarkMedia: MediaItem?
    @State private var lifecycleReplaysScheduled = 0
    @State private var homeNavigationPath: [ContentNavigationRoute] = []
    @State private var libraryNavigationPaths: [String: [ContentNavigationRoute]] = [:]
    // Discover owns both Jellyfin and Seerr results, so its stack needs to
    // carry both route types. NavigationPath keeps those identities separate
    // while still allowing a local result and a Seerr result to share a page.
    @State private var discoverNavigationPath = NavigationPath()
    @State private var regressionResolution = "idle"

    var body: some View {
        TabView {
            Tab("Home", systemImage: "house.fill") {
                NavigationStack(path: $homeNavigationPath) {
                    HomeView()
                        .contentNavigationDestinations()
                }
            }

            Tab("Discover", systemImage: "sparkles") {
                NavigationStack(path: $discoverNavigationPath) {
                    DiscoverView()
                        .seerrNavigationDestinations()
                        .contentNavigationDestinations()
                }
            }

            ForEach(libraries) { library in
                Tab(library.name ?? "Library", systemImage: icon(for: library)) {
                    NavigationStack(path: libraryNavigationPath(for: library.id)) {
                        LibraryView(library: library)
                            .contentNavigationDestinations()
                    }
                }
            }

            Tab("Settings", systemImage: "gearshape.fill") {
                NavigationStack {
                    SettingsView()
                }
            }
        }
        .task {
            await loadLibraries()
        }
        .onChange(of: session.activeAccount?.id) { oldAccountID, newAccountID in
            guard oldAccountID != newAccountID else { return }
            // Content values belong to the account that fetched them. This
            // also dismisses an old user's detail if accounts are switched
            // without rebuilding MainTabView.
            homeNavigationPath.removeAll()
            libraryNavigationPaths.removeAll()
            discoverNavigationPath = NavigationPath()
        }
        // Headless hardware harness: resolve a named library item through
        // the app's existing signed-in client, then present the same player
        // path a user selection would. There is intentionally no Settings
        // UI for this launch-only diagnostic hook.
        .task {
            await launchBenchItemIfRequested()
        }
        // Presented from the TabView rather than a screen, so a Top Shelf
        // selection resumes playback whichever tab happens to be showing.
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .fullScreenCover(item: $playerItem, onDismiss: scheduleLifecycleReplayIfNeeded) { item in
            VideoPlayerView(playerItem: item)
                .preferredColorScheme(.dark)
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                if UserDefaults.standard.bool(forKey: "debug.lifecycleReplayBenchmark") {
                    PlaybackLifecycleRegressionProbe()
                }
                if UserDefaults.standard.bool(forKey: "debug.playerRegression") {
                    Text("Player fixture resolution")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(width: 1, height: 1)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Player fixture resolution")
                        .accessibilityValue(regressionResolution)
                        .accessibilityIdentifier("player.regression.resolution")
                        .allowsHitTesting(false)
                }
            }
        }
        #endif
        // Runs once the session exists: on a cold launch the request is
        // made before there is a client to fetch with, so it waits here
        // instead of being dropped.
        .task(id: "\(deepLinks.pendingItemID ?? ""):\(deepLinkRetry)") {
            guard let id = deepLinks.pendingItemID else { return }
            do {
                let item = try await session.client.item(id: id)
                guard !Task.isCancelled, deepLinks.pendingItemID == id else { return }
                playerItem = PlayerItem(media: item)
                deepLinks.pendingItemID = nil
                deepLinkError = nil
            } catch is CancellationError {
            } catch {
                guard deepLinks.pendingItemID == id else { return }
                deepLinkError = "The item couldn't be loaded. Check the server connection and try again."
            }
        }
        .alert("Couldn't Open Item", isPresented: Binding(
            get: { deepLinkError != nil },
            set: { if !$0 { deepLinkError = nil } }
        )) {
            Button("Try Again") {
                deepLinkError = nil
                deepLinkRetry += 1
            }
            Button("Cancel", role: .cancel) {
                deepLinkError = nil
                deepLinks.pendingItemID = nil
            }
        } message: {
            Text(deepLinkError ?? "The item couldn't be loaded.")
        }
    }

    /// Tabs are the app's *navigation*, not a content rail, so a transient
    /// failure must never collapse them (HEL-61). This used to be a one-shot
    /// `try?` assigning `[]`, which meant a single unlucky request at launch
    /// removed Movies and Shows for the rest of the session — and it failed
    /// in exactly the situation where recovery is likely: a server slow to
    /// wake, or a TV rejoining wi-fi as the app foregrounds.
    ///
    /// So: never assign on failure, and keep retrying with backoff until the
    /// server answers.
    private func loadLibraries() async {
        // Draw last session's tabs straight away; the fetch reconciles a
        // moment later. Without this the bar visibly pops from three tabs
        // to five on every cold start (HEL-61).
        if libraries.isEmpty {
            libraries = session.cachedLibraries()
        }
        var delay = Duration.seconds(2)
        while !Task.isCancelled {
            if let views = try? await session.client.userViews() {
                // Assigning only on success is what distinguishes an empty
                // library from a failed fetch: an empty result here really
                // is empty, and clears the cache with it.
                let tabs = views
                    .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }
                    .map(LibraryTab.init)
                libraries = tabs
                session.cacheLibraries(tabs)
                return
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    private func launchBenchItemIfRequested() async {
        let regressionRun = UserDefaults.standard.bool(forKey: "debug.playerRegression")
        guard (UserDefaults.standard.bool(forKey: "debug.frameLossBench") || regressionRun),
              deepLinks.pendingItemID == nil,
              let term = UserDefaults.standard.string(forKey: "debug.benchSearchTerm")?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !term.isEmpty else { return }
        regressionResolution = "resolving"

        let requestedSeries = UserDefaults.standard.string(forKey: "debug.regressionSeriesName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindVC1InSeries"),
           let requestedSeries,
           !requestedSeries.isEmpty {
            guard let seriesPage = try? await session.client.items(
                includeTypes: [.series],
                searchTerm: requestedSeries,
                limit: 20
            ),
            let series = seriesPage.items.first(where: {
                $0.name?.compare(
                    requestedSeries,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }),
            let episodes = try? await session.client.episodes(seriesId: series.id, seasonId: nil) else {
                print("RegressionResolve failed VC-1 series=\"\(requestedSeries)\"")
                regressionResolution = "error:VC-1 series lookup failed"
                return
            }
            for episode in episodes {
                guard let info = try? await session.client.playbackInfo(itemId: episode.id),
                      let source = info.mediaSources.first,
                      (source.mediaStreams ?? []).contains(where: {
                          $0.type == "Video" && ["vc1", "vc-1"].contains($0.codec?.lowercased() ?? "")
                      }) else { continue }
                print("RegressionResolve VC-1 series=\"\(requestedSeries)\" title=\"\(episode.name ?? "?")\" id=\(episode.id)")
                lifecycleBenchmarkMedia = episode
                regressionResolution = "resolved"
                playerItem = PlayerItem(media: episode, startFromBeginning: true)
                return
            }
            print("RegressionResolve no VC-1 episode series=\"\(requestedSeries)\"")
            regressionResolution = "missing:VC-1 episode"
            return
        }
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindEpisodeWithSuccessor") {
            let episodeItems: [MediaItem]
            if let requestedSeries, !requestedSeries.isEmpty {
                guard let seriesPage = try? await session.client.items(
                    includeTypes: [.series],
                    searchTerm: requestedSeries,
                    limit: 20
                ),
                let series = seriesPage.items.first(where: {
                    $0.name?.compare(
                        requestedSeries,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                }),
                let episodes = try? await session.client.episodes(
                    seriesId: series.id,
                    seasonId: nil
                ) else {
                    print("RegressionResolve failed handoff series=\"\(requestedSeries)\"")
                    regressionResolution = "missing:requested handoff series"
                    return
                }
                episodeItems = episodes
            } else {
                guard let page = try? await session.client.items(
                    includeTypes: [.episode],
                    sortBy: "SeriesSortName,ParentIndexNumber,IndexNumber",
                    limit: 100
                ) else {
                    print("RegressionResolve failed episode handoff library scan")
                    regressionResolution = "error:episode handoff library scan failed"
                    return
                }
                episodeItems = page.items
            }
            // Select the earliest of at least two catalogue episodes in one
            // series. This keeps resolution to one list request plus usually
            // one PlaybackInfo request; calling `episodeAfter` for every item
            // made a fixture-less public demo slow enough for XCTest's tvOS
            // runner watchdog. The actual player still exercises that API.
            let candidates = Dictionary(
                grouping: episodeItems.filter { $0.seriesId != nil },
                by: { $0.seriesId! }
            ).values.compactMap { episodes -> MediaItem? in
                guard episodes.count > 1 else { return nil }
                return episodes.min { lhs, rhs in
                    let lhsSeason = lhs.parentIndexNumber ?? Int.max
                    let rhsSeason = rhs.parentIndexNumber ?? Int.max
                    if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }
                    return (lhs.indexNumber ?? Int.max) < (rhs.indexNumber ?? Int.max)
                }
            }
            let requireDirectH264 = UserDefaults.standard.bool(
                forKey: "debug.regressionRequireDirectH264Successor"
            )
            for episode in candidates.prefix(20) {
                guard let info = try? await session.client.playbackInfo(itemId: episode.id),
                      let source = info.mediaSources.first,
                      (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }) else {
                    continue
                }
                if requireDirectH264 {
                    let isDirectH264 = source.supportsDirectPlay == true
                        && (source.mediaStreams ?? []).contains {
                            $0.type == "Video" && $0.codec?.lowercased() == "h264"
                        }
                    guard isDirectH264 else { continue }
                }
                print("RegressionResolve handoff title=\"\(episode.name ?? "?")\" id=\(episode.id)")
                lifecycleBenchmarkMedia = episode
                regressionResolution = "resolved"
                playerItem = PlayerItem(media: episode, startFromBeginning: true)
                return
            }
            print("RegressionResolve no playable episode with a successor")
            regressionResolution = "missing:playable episode with successor"
            return
        }
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindDirectStream") {
            guard let page = try? await session.client.items(
                includeTypes: [.movie, .episode],
                limit: 100
            ) else {
                print("RegressionResolve failed direct-stream library scan")
                regressionResolution = "error:direct-stream library scan failed"
                return
            }
            for item in page.items {
                guard let info = try? await session.client.playbackInfo(itemId: item.id),
                      let source = info.mediaSources.first,
                      source.supportsDirectPlay != true,
                      source.supportsDirectStream == true,
                      (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }) else {
                    continue
                }
                print("RegressionResolve direct-stream title=\"\(item.name ?? "?")\" id=\(item.id)")
                lifecycleBenchmarkMedia = item
                regressionResolution = "resolved"
                playerItem = PlayerItem(media: item, startFromBeginning: true)
                return
            }
            print("RegressionResolve no direct-stream item")
            regressionResolution = "missing:direct-stream item"
            return
        }
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindPlayable") {
            guard let page = try? await session.client.items(
                includeTypes: [.movie, .episode],
                limit: 100
            ) else {
                print("RegressionResolve failed playable library scan")
                regressionResolution = "error:playable library scan failed"
                return
            }
            for item in page.items {
                guard let info = try? await session.client.playbackInfo(itemId: item.id),
                      let source = info.mediaSources.first,
                      (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }) else {
                    continue
                }
                print("RegressionResolve playable title=\"\(item.name ?? "?")\" id=\(item.id)")
                lifecycleBenchmarkMedia = item
                regressionResolution = "resolved"
                playerItem = PlayerItem(media: item, startFromBeginning: true)
                return
            }
            print("RegressionResolve no playable item")
            regressionResolution = "missing:playable item"
            return
        }
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindMultiAudioH264") {
            guard let page = try? await session.client.items(
                includeTypes: [.movie, .episode],
                limit: 100
            ) else {
                print("RegressionResolve failed multi-audio library scan")
                regressionResolution = "error:multi-audio library scan failed"
                return
            }
            // Ask the server which sources are direct-playable under the
            // simulator profile. That preserves every embedded audio stream
            // and avoids baking a private-library title into the regression.
            for item in page.items {
                guard let info = try? await session.client.playbackInfo(itemId: item.id),
                      let source = info.mediaSources.first(where: { $0.supportsDirectPlay == true }) else {
                    continue
                }
                let streams = source.mediaStreams ?? []
                let isH264 = streams.contains {
                    $0.type == "Video" && $0.codec?.lowercased() == "h264"
                }
                let audioCount = streams.count { $0.type == "Audio" }
                if isH264, audioCount > 1 {
                    print("RegressionResolve multi-audio title=\"\(item.name ?? "?")\" id=\(item.id)")
                    regressionResolution = "resolved"
                    playerItem = PlayerItem(media: item, startFromBeginning: true)
                    return
                }
            }
            print("RegressionResolve no direct-play H.264 multi-audio item")
            regressionResolution = "missing:direct-play H.264 multi-audio item"
            return
        }
        if regressionRun,
           UserDefaults.standard.bool(forKey: "debug.regressionFindSkippableEpisode"),
           let requestedSeries,
           !requestedSeries.isEmpty {
            guard let seriesPage = try? await session.client.items(
                includeTypes: [.series],
                searchTerm: requestedSeries,
                limit: 20
            ),
            let series = seriesPage.items.first(where: {
                $0.name?.compare(
                    requestedSeries,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }),
            let episodes = try? await session.client.episodes(seriesId: series.id, seasonId: nil) else {
                print("RegressionResolve failed series=\"\(requestedSeries)\"")
                regressionResolution = "missing:requested skippable series"
                return
            }
            for episode in episodes {
                let segments = await session.client.mediaSegments(itemId: episode.id)
                if segments.contains(where: { $0.kind.isSkippable }) {
                    print("RegressionResolve skippable series=\"\(requestedSeries)\" title=\"\(episode.name ?? "?")\" id=\(episode.id)")
                    regressionResolution = "resolved"
                    playerItem = PlayerItem(media: episode, startFromBeginning: true)
                    return
                }
            }
            print("RegressionResolve no skippable episode series=\"\(requestedSeries)\"")
            regressionResolution = "missing:skippable episode"
            return
        }

        guard let page = try? await session.client.items(
            includeTypes: regressionRun ? [.movie, .episode] : [.movie],
            searchTerm: term,
            limit: regressionRun ? 100 : 20
        ) else {
            print("BenchResolve failed term=\"\(term)\"")
            regressionResolution = "error:item lookup failed"
            return
        }
        let requestedYear = UserDefaults.standard.integer(forKey: "debug.benchProductionYear")
        let candidates = page.items.filter {
            $0.name?.compare(term, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                && (requestedSeries?.isEmpty != false
                    || $0.seriesName?.compare(
                        requestedSeries!,
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame)
        }
        let item = candidates.first(where: { requestedYear <= 0 || $0.productionYear == requestedYear })
            ?? candidates.first
        guard let item else {
            print("BenchResolve no exact match term=\"\(term)\" year=\(requestedYear)")
            regressionResolution = "missing:exact media fixture"
            return
        }
        print("BenchResolve title=\"\(item.name ?? term)\" year=\(item.productionYear ?? 0) id=\(item.id)")
        regressionResolution = "resolved"
        playerItem = PlayerItem(media: item, startFromBeginning: regressionRun)
    }

    private func scheduleLifecycleReplayIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "debug.lifecycleReplayBenchmark"),
              let lifecycleBenchmarkMedia else { return }
        let configuredCount = UserDefaults.standard.integer(forKey: "debug.lifecycleReplayCount")
        let replayCount = configuredCount > 0 ? configuredCount : 1
        guard lifecycleReplaysScheduled < replayCount else { return }
        lifecycleReplaysScheduled += 1
        let replayNumber = lifecycleReplaysScheduled + 1
        let configuredDelay = UserDefaults.standard.double(forKey: "debug.lifecycleReplayDelaySeconds")
        let delay = configuredDelay > 0 ? configuredDelay : 12
        Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, playerItem == nil else { return }
            let lifecycle = PlaybackLifecycleDiagnostics.snapshot()
            print("LifecycleReplay beforeSession=\(replayNumber) \(lifecycle.regressionValue)")
            playerItem = PlayerItem(media: lifecycleBenchmarkMedia, startFromBeginning: true)
        }
    }

    private func icon(for library: LibraryTab) -> String {
        library.collectionType == "tvshows" ? "tv" : "film"
    }

    private func libraryNavigationPath(
        for libraryID: String
    ) -> Binding<[ContentNavigationRoute]> {
        Binding(
            get: { libraryNavigationPaths[libraryID] ?? [] },
            set: { libraryNavigationPaths[libraryID] = $0 }
        )
    }
}

#if DEBUG
/// Non-focusable XCTest probe shown only for the launch-gated lifecycle run.
/// A periodic view is used because teardown completes off-main and therefore
/// does not otherwise invalidate SwiftUI when a counter reaches zero.
private struct PlaybackLifecycleRegressionProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let snapshot = PlaybackLifecycleDiagnostics.snapshot()
            Text("Playback lifecycle")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityIdentifier("app.lifecycle.state")
                .accessibilityValue(snapshot.regressionValue)
                .allowsHitTesting(false)
        }
    }
}
#endif

/// Routes an item to the right detail screen off its type.
struct ItemDetailRouter: View {
    let item: MediaItem

    var body: some View {
        Group {
            switch item.type {
            case .series:
                SeriesDetailView(item: item)
            default:
                ItemDetailView(item: item)
            }
        }
        .accessibilityIdentifier("detail.item.\(item.id)")
        .accessibilityValue(item.name ?? "Item")
    }
}

import SwiftUI
import LagoonEngine

private enum MainTabSelection: Hashable {
    case home
    case discover
    case library
    case search
    case settings
}

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SyncPlayStore.self) private var syncPlay
    @Environment(DeepLinkRouter.self) private var deepLinks
    @Environment(ServerSyncState.self) private var serverSync
    @State private var libraries: [LibraryTab] = []
    @State private var librariesLoaded = false
    @State private var playerItem: PlayerItem?
    #if os(iOS)
    /// The one iOS player host; every screen's `playerPresentation` goes through it.
    @State private var playerHub = PlayerPresentationHub()
    /// The offline-launch tab switch happens once per session, not on every retry.
    @State private var hasSwitchedToLibraryForOfflineDownloads = false
    #endif
    @State private var deepLinkError: String?
    @State private var deepLinkRetry = 0
    @State private var lifecycleBenchmarkMedia: MediaItem?
    @State private var lifecycleReplaysScheduled = 0
    @State private var homeNavigationPath: [ContentNavigationRoute] = []
    @State private var libraryNavigationPath: [ContentNavigationRoute] = []
    // Discover and Search push both Jellyfin and Seerr routes, so their
    // stacks are heterogeneous `NavigationPath`s.
    @State private var discoverNavigationPath = NavigationPath()
    @State private var searchNavigationPath = NavigationPath()
    @State private var regressionResolution = "idle"
    @State private var selectedTab: MainTabSelection = .home
    #if os(tvOS)
    @State private var hasMountedServerRefresh = false
    @State private var refreshTopChromeOffset: CGFloat = 0
    #endif
    @FocusState private var homeHeroFocused: Bool
    @FocusState private var settingsFirstCategoryFocused: Bool
    @State private var showsProfilePicker = false
    @State private var addsProfileAfterPicker = false
    /// The active profile's portrait for the chrome: the top-right button on
    /// tvOS, the Settings tab icon on iOS.
    @State private var profileImage: UIImage?
    /// Tab roots on screen; a pushed page takes its tab's root away.
    @State private var visibleTabRoots: Set<MainTabSelection> = []
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        primaryNavigation
        #if os(tvOS)
        .overlay(alignment: .topLeading) {
            if hasMountedServerRefresh || serverSync.activeTarget != nil {
                // Bound to its isolation here: passed inline, the compiler
                // treats it as callable from any actor. UIKit focus calls it
                // on the main actor.
                let moveDown: (@MainActor @Sendable () -> Void)? = activeRefreshMoveDownAction
                ServerRefreshButton(
                    target: serverSync.activeTarget,
                    moveDownAction: moveDown,
                    topChromeOffset: $refreshTopChromeOffset
                )
                    // Aligns the circle with the hero and rails. The focus
                    // frame overhangs the glass slightly; the alignment UI
                    // test allows for it.
                    .padding(.leading, Metrics.screenGutter)
                    .offset(y: -Metrics.Space.m)
                    .onAppear { hasMountedServerRefresh = true }
            }
        }
        .overlay(alignment: .topTrailing) {
            if let account = session.activeAccount {
                let moveDown: (@MainActor @Sendable () -> Void)? = profileMoveDownAction
                ProfileButton(
                    image: profileImage,
                    profileName: account.displayName,
                    isAvailable: showsProfileButton,
                    moveDownAction: moveDown,
                    action: openProfilePicker
                )
                    .padding(.trailing, Metrics.screenGutter)
                    .offset(y: -Metrics.Space.m)
            }
        }
        #endif
        .task(id: profileImageKey) {
            guard let account = session.activeAccount else {
                profileImage = nil
                return
            }
            let image = await ProfilePortrait.image(
                for: account,
                size: Metrics.chromeProfilePortraitSize,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            profileImage = image
        }
        .environment(\.openProfilePicker, openProfilePicker)
        #if os(tvOS)
        .fullScreenCover(isPresented: $showsProfilePicker, onDismiss: addProfileAfterPicker) {
            profilePicker
        }
        #else
        .sheet(isPresented: $showsProfilePicker, onDismiss: addProfileAfterPicker) {
            profilePicker
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        #endif
        .task(id: "\(session.activeAccount?.id ?? ""):\(serverSync.generation)") {
            await loadLibraries()
        }
        .onChange(of: session.activeAccount?.id) { oldAccountID, newAccountID in
            guard oldAccountID != newAccountID else { return }
            // Content belongs to the account that fetched it; drop the old
            // user's stacks even if MainTabView is not rebuilt.
            homeNavigationPath.removeAll()
            libraryNavigationPath.removeAll()
            libraries = session.cachedLibraries()
            librariesLoaded = false
            discoverNavigationPath = NavigationPath()
            searchNavigationPath = NavigationPath()
            playerItem = nil
            deepLinks.clear()
        }
        // Launch-only harness hooks: resolve a named item with the signed-in
        // client and present it the way a user selection would.
        .task {
            await launchBenchItemIfRequested()
            #if DEBUG
            await openDetailIfRequested()
            await joinSyncPlayGroupIfRequested()
            #if os(iOS)
            await downloadItemIfRequested()
            #endif
            #endif
        }
        // A SyncPlay group can start playback while any screen is showing,
        // so the player is presented from the tab root.
        .onChange(of: syncPlay.pendingPlayRequest?.id) { _, request in
            guard request != nil, let play = syncPlay.pendingPlayRequest else { return }
            syncPlay.pendingPlayRequest = nil
            playerItem = PlayerItem(
                media: play.media,
                startPosition: play.startSeconds,
                startPaused: true,
                groupPlaylistItemId: play.playlistItemId
            )
        }
        // On the TabView so a Top Shelf selection plays from any tab.
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: scheduleLifecycleReplayIfNeeded)
        #if os(iOS)
        .environment(playerHub)
        .playerPresentationHost(playerHub)
        #endif
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
        // On a cold launch the link arrives before the client exists; it
        // waits here instead of being dropped.
        .task(id: "\(deepLinks.pendingItemID ?? ""):\(deepLinkRetry)") {
            guard let id = deepLinks.pendingItemID else { return }
            guard deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else {
                deepLinks.clear()
                return
            }
            do {
                let item = try await session.client.item(id: id)
                guard !Task.isCancelled, deepLinks.pendingItemID == id,
                      deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else { return }
                playerItem = PlayerItem(media: item)
                deepLinks.pendingItemID = nil
                deepLinkError = nil
            } catch is CancellationError {
            } catch {
                guard deepLinks.pendingItemID == id else { return }
                deepLinkError = "The item couldn't be loaded. Check the server connection and try again."
            }
        }
        // Top Shelf More Info opens the detail page on Home's stack.
        .task(id: "\(deepLinks.pendingDetailItemID ?? ""):\(deepLinkRetry)") {
            guard let id = deepLinks.pendingDetailItemID else { return }
            guard deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else {
                deepLinks.clear()
                return
            }
            do {
                let item = try await session.client.item(id: id)
                guard !Task.isCancelled, deepLinks.pendingDetailItemID == id,
                      deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else { return }
                homeNavigationPath.append(ContentNavigationRoute.item(item))
                deepLinks.pendingDetailItemID = nil
                deepLinkError = nil
            } catch is CancellationError {
            } catch {
                guard deepLinks.pendingDetailItemID == id else { return }
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
                deepLinks.pendingDetailItemID = nil
            }
        } message: {
            Text(deepLinkError ?? "The item couldn't be loaded.")
        }
    }

    #if os(tvOS)
    private var activeRefreshMoveDownAction: (@MainActor @Sendable () -> Void)? {
        guard let target = serverSync.activeTarget else { return nil }
        return refreshMoveDownAction(for: target)
    }

    private func refreshMoveDownAction(
        for target: ServerSyncTarget
    ) -> (@MainActor @Sendable () -> Void)? {
        switch target {
        case .home:
            return focusHomeHero
        case .discover, .library:
            return nil
        }
    }

    private func focusHomeHero() {
        homeHeroFocused = true
    }

    /// Down from the profile button goes into the page below it, not to the
    /// tab bar beside it: Home's hero, as from Refresh, or Settings' first
    /// category, the tab it is reached from.
    private var profileMoveDownAction: (@MainActor @Sendable () -> Void)? {
        switch selectedTab {
        case .home: focusHomeHero
        case .settings: focusSettingsFirstCategory
        case .discover, .library, .search: nil
        }
    }

    private func focusSettingsFirstCategory() {
        settingsFirstCategoryFocused = true
    }

    /// Like Refresh, only over a content tab's root with nothing pushed. In
    /// Settings it stays on every page: it is reached Right from Settings'
    /// tab, which stays focusable above them.
    private var showsProfileButton: Bool {
        switch selectedTab {
        case .home: visibleTabRoots.contains(.home) && homeNavigationPath.isEmpty
        case .discover: visibleTabRoots.contains(.discover) && discoverNavigationPath.isEmpty
        case .library: visibleTabRoots.contains(.library) && libraryNavigationPath.isEmpty
        case .search: visibleTabRoots.contains(.search) && searchNavigationPath.isEmpty
        case .settings: true
        }
    }
    #endif

    /// Redraws the portrait when the profile, its picture or its name changes.
    private var profileImageKey: String {
        guard let account = session.activeAccount else { return "" }
        return "\(account.id)|\(account.primaryImageTag ?? "")|\(account.displayName)|\(displayScale)"
    }

    private var primaryNavigation: some View {
        TabView(selection: $selectedTab) {
            Tab("Home", systemImage: ContentIcon.home, value: MainTabSelection.home) {
                NavigationStack(path: $homeNavigationPath) {
                    HomeView(
                        isActive: selectedTab == .home && homeNavigationPath.isEmpty,
                        heroFocus: $homeHeroFocused
                    )
                        .tabRoot(.home, in: $visibleTabRoots)
                        .contentNavigationDestinations()
                        .themedChrome()
                }
            }

            Tab("Discover", systemImage: ContentIcon.discover, value: MainTabSelection.discover) {
                NavigationStack(path: $discoverNavigationPath) {
                    DiscoverView(
                        isActive: selectedTab == .discover && discoverNavigationPath.isEmpty
                    )
                        .tabRoot(.discover, in: $visibleTabRoots)
                        .seerrNavigationDestinations()
                        .contentNavigationDestinations()
                        .themedChrome()
                }
            }

            Tab("Library", systemImage: ContentIcon.libraries, value: MainTabSelection.library) {
                NavigationStack(path: $libraryNavigationPath) {
                    LibraryView(
                        accountID: session.activeAccount?.id ?? "",
                        libraries: libraries,
                        librariesLoaded: librariesLoaded,
                        isActive: selectedTab == .library && libraryNavigationPath.isEmpty
                    )
                        .id(session.activeAccount?.id)
                        .tabRoot(.library, in: $visibleTabRoots)
                        .contentNavigationDestinations()
                        .themedChrome()
                }
            }

            // Search is its own tab: on tvOS `.searchable` draws a resident
            // keyboard and expects to own the screen.
            Tab(
                "Search",
                systemImage: ContentIcon.search,
                value: MainTabSelection.search,
                role: .search
            ) {
                NavigationStack(path: $searchNavigationPath) {
                    SearchView()
                        .tabRoot(.search, in: $visibleTabRoots)
                        .seerrNavigationDestinations()
                        .contentNavigationDestinations()
                        .themedChrome()
                }
            }

            Tab(value: MainTabSelection.settings) {
                NavigationStack {
                    SettingsView(firstCategoryFocus: $settingsFirstCategoryFocused)
                        .themedChrome()
                }
                #if os(iOS)
                .environment(\.showDownloadsList, showDownloadsList)
                #endif
            } label: {
                settingsTabLabel
            }
        }
    }

    /// On iOS the gear gives way to the active profile's portrait, drawn
    /// untinted; Settings is where the profile is switched.
    @ViewBuilder
    private var settingsTabLabel: some View {
        #if os(iOS)
        if let profileImage {
            Label {
                Text("Settings")
            } icon: {
                Image(uiImage: profileImage)
                    .renderingMode(.original)
            }
        } else {
            Label("Settings", systemImage: ContentIcon.settings)
        }
        #else
        Label("Settings", systemImage: ContentIcon.settings)
        #endif
    }

    #if os(iOS)
    /// Settings > Downloads > Show Downloads switches to Library and replaces
    /// its stack with the downloads list.
    private func showDownloadsList() {
        selectedTab = .library
        if libraryNavigationPath != [.downloads] {
            libraryNavigationPath = [.downloads]
        }
    }
    #endif

    private func openProfilePicker() {
        showsProfilePicker = true
    }

    private var profilePicker: some View {
        AccountPickerView(isPresentedFromApp: true) {
            addsProfileAfterPicker = true
            showsProfilePicker = false
        }
    }

    /// Two covers cannot overlap: RootView's add-profile cover waits until
    /// the picker is gone.
    private func addProfileAfterPicker() {
        guard addsProfileAfterPicker else { return }
        addsProfileAfterPicker = false
        session.addAccount()
    }

    /// Retries with backoff; the cached list stands in until a fetch succeeds.
    private func loadLibraries() async {
        let accountID = session.activeAccount?.id
        if libraries.isEmpty {
            libraries = session.cachedLibraries()
        }
        var delay = Duration.seconds(2)
        var isFirstAttempt = true
        while !Task.isCancelled {
            if let views = try? await session.client.userViews() {
                guard !Task.isCancelled, accountID == session.activeAccount?.id else { return }
                // Only a success assigns, so an empty result really is empty
                // and clears the cache.
                let tabs = views
                    .filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }
                    .map(LibraryTab.init)
                libraries = tabs
                librariesLoaded = true
                session.cacheLibraries(tabs)
                serverSync.serverUnreachable = false
                #if os(iOS)
                await DownloadStore.shared.flushPendingReports(client: session.client)
                #endif
                return
            }
            if isFirstAttempt {
                isFirstAttempt = false
                serverSync.serverUnreachable = true
                // Offline with downloads: land on Library, not an empty Home.
                #if os(iOS)
                if !hasSwitchedToLibraryForOfflineDownloads, !DownloadStore.shared.entries.isEmpty {
                    hasSwitchedToLibraryForOfflineDownloads = true
                    selectedTab = .library
                }
                #endif
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(30))
        }
    }

    #if DEBUG
    /// `-debug.openDetailItemID <id>` pushes the item's detail page on Home,
    /// skipping the "Open in Lagoon?" prompt `simctl openurl` raises.
    private func openDetailIfRequested() async {
        guard let itemID = UserDefaults.standard.string(forKey: "debug.openDetailItemID"), !itemID.isEmpty,
              let item = try? await session.client.item(id: itemID) else { return }
        homeNavigationPath.append(ContentNavigationRoute.item(item))
    }

    /// `-debug.syncPlayJoinGroup <name>` joins that group. The other member
    /// usually creates it a moment later, so the list is polled.
    private func joinSyncPlayGroupIfRequested() async {
        guard let name = UserDefaults.standard.string(forKey: "debug.syncPlayJoinGroup")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let groups = await syncPlay.refreshGroups()
            if let group = groups.first(where: {
                $0.groupName.compare(name, options: [.caseInsensitive]) == .orderedSame
            }) {
                print("SyncPlayJoin joining \"\(name)\"")
                await syncPlay.join(group)
                return
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
        print("SyncPlayJoin no group named \"\(name)\" appeared")
    }

    #if os(iOS)
    /// `-debug.downloadItemID <id>` starts a download headlessly.
    /// `-debug.downloadQuality` is `original`, `high` (default) or
    /// `standard`; `-debug.downloadRestart YES` deletes an existing entry first.
    private func downloadItemIfRequested() async {
        guard let itemID = UserDefaults.standard.string(forKey: "debug.downloadItemID"), !itemID.isEmpty else { return }
        let store = DownloadStore.shared
        if let existing = store.entry(for: itemID) {
            guard UserDefaults.standard.bool(forKey: "debug.downloadRestart") else {
                print("Downloads: skipping \(itemID), entry already exists (state=\(existing.state.rawValue))")
                return
            }
            store.delete(itemID)
        }
        let qualityRaw = UserDefaults.standard.string(forKey: "debug.downloadQuality") ?? "high"
        let quality = DownloadQuality(rawValue: qualityRaw) ?? .high
        guard let item = try? await session.client.item(id: itemID) else {
            print("Downloads: couldn't fetch item \(itemID)")
            return
        }
        guard let source = item.mediaSources?.first else {
            print("Downloads: item \(itemID) has no media source")
            return
        }
        do {
            try await store.start(item: item, source: source, quality: quality, client: session.client)
            print("Downloads: started \(itemID) quality=\(quality.rawValue)")
        } catch {
            print("Downloads: failed to start \(itemID): \(error)")
        }
    }
    #endif
    #endif

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
            // Keep "no such series" (`missing:`, skips the journey) apart
            // from "request failed" (`error:`, fails it), or a server without
            // the fixture reads as a broken player.
            guard let seriesPage = try? await session.client.items(
                includeTypes: [.series],
                searchTerm: requestedSeries,
                limit: 20
            ) else {
                print("RegressionResolve failed VC-1 series search=\"\(requestedSeries)\"")
                regressionResolution = "error:VC-1 series search failed"
                return
            }
            guard let series = seriesPage.items.first(where: {
                $0.name?.compare(
                    requestedSeries,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) else {
                print("RegressionResolve no VC-1 series named \"\(requestedSeries)\"")
                regressionResolution = "missing:series \(requestedSeries)"
                return
            }
            guard let episodes = try? await session.client.episodes(
                seriesId: series.id,
                seasonId: nil
            ) else {
                print("RegressionResolve failed VC-1 episode list for \"\(requestedSeries)\"")
                regressionResolution = "error:VC-1 episode list failed"
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
            // Pick the earliest episode of any series with two or more.
            // Calling `episodeAfter` per item was slow enough to trip the
            // XCTest watchdog on the demo server.
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
            // Journeys that need direct play ask for it, so a server whose
            // first title transcodes yields a skip, not a timeout.
            let requireDirectPlay = UserDefaults.standard.bool(forKey: "debug.regressionRequireDirectPlay")
            let requireAudio = UserDefaults.standard.bool(forKey: "debug.regressionRequireAudio")
            for item in page.items {
                guard let info = try? await session.client.playbackInfo(itemId: item.id),
                      let source = info.mediaSources.first,
                      (source.mediaStreams ?? []).contains(where: { $0.type == "Video" }),
                      !requireDirectPlay || source.supportsDirectPlay == true,
                      !requireAudio || (source.mediaStreams ?? []).contains(where: { $0.type == "Audio" }) else {
                    continue
                }
                print("RegressionResolve playable title=\"\(item.name ?? "?")\" id=\(item.id)")
                lifecycleBenchmarkMedia = item
                regressionResolution = "resolved"
                playerItem = PlayerItem(media: item, startFromBeginning: true)
                return
            }
            print("RegressionResolve no playable item (directPlay=\(requireDirectPlay), audio=\(requireAudio))")
            regressionResolution = requireDirectPlay ? "missing:direct-play playable item" : "missing:playable item"
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
            // Direct play keeps every embedded audio stream; asking the
            // server avoids hard-coding a private-library title.
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

}

#if DEBUG
/// XCTest probe for the lifecycle run. Polls, because teardown finishes
/// off-main and would not otherwise invalidate SwiftUI.
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
            case .boxSet:
                CollectionDetailView(item: item)
            default:
                ItemDetailView(item: item)
            }
        }
        .accessibilityIdentifier("detail.item.\(item.id)")
        .accessibilityValue(item.name ?? "Item")
    }
}

private extension View {
    /// Records whether a tab's root is on screen, for the tvOS profile
    /// button. iOS has no use for it.
    @ViewBuilder
    func tabRoot(_ tab: MainTabSelection, in roots: Binding<Set<MainTabSelection>>) -> some View {
        #if os(tvOS)
        onAppear { roots.wrappedValue.insert(tab) }
            .onDisappear { roots.wrappedValue.remove(tab) }
        #else
        self
        #endif
    }
}

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
    #if os(tvOS)
    @FocusState private var refreshFocused: Bool
    @FocusState private var profileFocused: Bool
    #endif
    @State private var showsProfilePicker = false
    @State private var addsProfileAfterPicker = false
    @State private var profileAfterPicker: StoredAccount?
    /// The active profile's portrait for the chrome: the top-left button on
    /// tvOS, the Settings tab icon on iOS.
    @State private var profileImage: UIImage?
    /// Tab roots on screen; a pushed page takes its tab's root away.
    @State private var visibleTabRoots: Set<MainTabSelection> = []
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        primaryNavigation
        #if os(tvOS)
        .overlay(alignment: .topLeading) {
            // Refresh, then the profile button on the tab bar's side of it, so
            // the profile is one Left from Home. One container: focus crosses
            // between them, and the profile keeps its place where Refresh is
            // hidden.
            HStack(spacing: Metrics.Space.xl) {
                if hasMountedServerRefresh || serverSync.activeTarget != nil {
                    // Bound to its isolation here: passed inline, the compiler
                    // treats it as callable from any actor. UIKit focus calls
                    // it on the main actor.
                    let moveDown: (@MainActor @Sendable () -> Void)? = activeRefreshMoveDownAction
                    let moveRight: (@MainActor @Sendable () -> Void)? = refreshMoveRightAction
                    ServerRefreshButton(
                        target: serverSync.activeTarget,
                        moveDownAction: moveDown,
                        moveRightAction: moveRight,
                        topChromeOffset: $refreshTopChromeOffset
                    )
                        .focused($refreshFocused)
                        .onAppear { hasMountedServerRefresh = true }
                } else {
                    Color.clear
                        .frame(width: Metrics.topChromeButtonSize, height: Metrics.topChromeButtonSize)
                }
                if let account = session.activeAccount {
                    let moveDown: (@MainActor @Sendable () -> Void)? = profileMoveDownAction
                    let moveLeft: (@MainActor @Sendable () -> Void)? = profileMoveLeftAction
                    ProfileButton(
                        image: profileImage,
                        profileName: account.displayName,
                        isAvailable: showsProfileButton,
                        moveDownAction: moveDown,
                        moveLeftAction: moveLeft,
                        action: openProfilePicker
                    )
                        .focused($profileFocused)
                }
            }
                // Aligns Refresh's circle with the hero and rails. The focus
                // frame overhangs the glass slightly; the alignment UI test
                // allows for it.
                .padding(.leading, Metrics.screenGutter)
                .offset(y: -Metrics.Space.m)
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
        .fullScreenCover(isPresented: $showsProfilePicker, onDismiss: finishProfilePicker) {
            profilePicker
        }
        #else
        .sheet(isPresented: $showsProfilePicker, onDismiss: finishProfilePicker) {
            profilePicker
                .presentationDetents(profilePickerDetents)
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
                startPaused: true
            )
        }
        // On the TabView so a Top Shelf selection plays from any tab.
        .restoresFocusAfterPlayer(isPresented: playerItem != nil)
        .playerPresentation(item: $playerItem, onDismiss: scheduleLifecycleReplayIfNeeded)
        #if os(iOS)
        .environment(playerHub)
        .environment(\.playerCover, playerHub)
        .playerPresentationHost(playerHub)
        #else
        .environment(\.playerCover, PlayerPresence.shared)
        #endif
        #if DEBUG
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading) {
                if UserDefaults.standard.bool(forKey: "debug.lifecycleReplayBenchmark") {
                    PlaybackLifecycleRegressionProbe()
                }
                if UserDefaults.standard.bool(forKey: "debug.playerRegression") {
                    RegressionProbe(
                        label: "Player fixture resolution",
                        identifier: "player.regression.resolution",
                        value: regressionResolution
                    )
                }
            }
        }
        #endif
        // On a cold launch the link arrives before the client exists; it
        // waits here instead of being dropped.
        .task(id: "\(deepLinks.pendingItemID ?? ""):\(deepLinkRetry)") {
            await resolveDeepLinkItem(pendingID: \.pendingItemID) { item in
                playerItem = PlayerItem(media: item)
            }
        }
        // Top Shelf More Info opens the detail page on Home's stack.
        .task(id: "\(deepLinks.pendingDetailItemID ?? ""):\(deepLinkRetry)") {
            await resolveDeepLinkItem(pendingID: \.pendingDetailItemID) { item in
                homeNavigationPath.append(ContentNavigationRoute.item(item))
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

    /// Resolves a Top Shelf deep link once the signed-in client exists, and
    /// hands the item to `onResolved`. Play and open-detail links differ only
    /// in what happens with the resolved item.
    private func resolveDeepLinkItem(
        pendingID: ReferenceWritableKeyPath<DeepLinkRouter, String?>,
        onResolved: (MediaItem) -> Void
    ) async {
        guard let id = deepLinks[keyPath: pendingID] else { return }
        guard deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else {
            deepLinks.clear()
            return
        }
        do {
            let item = try await session.client.item(id: id)
            guard !Task.isCancelled, deepLinks[keyPath: pendingID] == id,
                  deepLinks.isCurrent(itemID: id, accountID: session.activeAccount?.id) else { return }
            onResolved(item)
            deepLinks[keyPath: pendingID] = nil
            deepLinkError = nil
        } catch is CancellationError {
        } catch {
            guard deepLinks[keyPath: pendingID] == id else { return }
            deepLinkError = "The item couldn't be loaded. Check the server connection and try again."
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

    /// Down from the profile button goes into Home's hero, as from Refresh,
    /// not sideways to the tab bar. It is reached Left from Home, and
    /// focusing a tab selects it, so Home is the only tab it is reached from.
    private var profileMoveDownAction: (@MainActor @Sendable () -> Void)? {
        guard selectedTab == .home else { return nil }
        return focusHomeHero
    }

    /// Left from the profile button to Refresh, where Refresh is shown.
    private var profileMoveLeftAction: (@MainActor @Sendable () -> Void)? {
        guard serverSync.activeTarget != nil else { return nil }
        return focusRefresh
    }

    /// Right from Refresh to the profile button, where it is shown.
    private var refreshMoveRightAction: (@MainActor @Sendable () -> Void)? {
        guard session.activeAccount != nil, showsProfileButton else { return nil }
        return focusProfile
    }

    private func focusRefresh() {
        refreshFocused = true
    }

    private func focusProfile() {
        profileFocused = true
    }

    /// Like Refresh, only over a content tab's root with nothing pushed. In
    /// Settings it stays on every page, showing who is signed in.
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
                    SettingsView()
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

    #if os(iOS)
    /// Half height cuts a second server's profiles off mid-portrait, so
    /// several servers open the picker full height.
    private var profilePickerDetents: Set<PresentationDetent> {
        ProfileGrouping.groups(session.accounts).count > 1 ? [.large] : [.medium, .large]
    }
    #endif

    private var profilePicker: some View {
        AccountPickerView(
            isPresentedFromApp: true,
            onAddProfile: {
                addsProfileAfterPicker = true
                showsProfilePicker = false
            },
            onSwitchProfile: { account in
                profileAfterPicker = account
                showsProfilePicker = false
            }
        )
    }

    /// Both wait until the picker is gone. Two covers cannot overlap, so
    /// RootView's add-profile cover has to. A switch done under the closing
    /// picker repaints it in the new profile's theme on its way out; after
    /// it, the new profile arrives whole, under its theme's bloom.
    private func finishProfilePicker() {
        if let account = profileAfterPicker {
            profileAfterPicker = nil
            session.switchTo(account)
        } else if addsProfileAfterPicker {
            addsProfileAfterPicker = false
            session.addAccount()
        }
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
        guard deepLinks.pendingItemID == nil else { return }
        let resolver = LaunchFixtureResolver(client: session.client)
        guard resolver.isRequested else { return }
        regressionResolution = "resolving"
        switch await resolver.resolve() {
        case .notRequested:
            break
        case .unresolved(let probe):
            regressionResolution = probe
        case .resolved(let item, let startFromBeginning, let replaysLifecycle):
            if replaysLifecycle { lifecycleBenchmarkMedia = item }
            regressionResolution = "resolved"
            playerItem = PlayerItem(media: item, startFromBeginning: startFromBeginning)
        }
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
            RegressionProbe(
                label: "Playback lifecycle",
                identifier: "app.lifecycle.state",
                value: snapshot.regressionValue
            )
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

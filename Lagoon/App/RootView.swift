import SwiftUI

/// Switches between onboarding and the main UI off the session phase.
struct RootView: View {
    @State private var session = SessionStore()
    private var seerr: SeerrSessionStore { session.seerr }
    private var syncPlay: SyncPlayStore { session.syncPlay }
    @State private var serverSync = ServerSyncState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            switch session.phase {
            case .needsServer:
                ServerConnectView()
            case .needsSignIn:
                SignInView()
            case .choosingAccount:
                AccountPickerView()
            case .signedIn:
                MainTabView()
                    .id(session.activeAccount?.id)
            }
        }
        .animation(.easeInOut(duration: Motion.standard), value: session.phase)
        // The theme is per profile. The bloom sits over everything so a
        // change in Settings shows across the whole screen.
        .themedControls()
        .overlay { ThemeBloomOverlay() }
        .environment(session)
        .environment(\.jellyfinClient, session.client)
        #if os(iOS)
        .environment(\.itemDownloads, DownloadStore.shared)
        #endif
        .environment(seerr)
        .environment(syncPlay)
        .environment(serverSync)
        .fullScreenCover(isPresented: Binding(
            get: { session.isAddingAccount },
            set: { session.isAddingAccount = $0 }
        )) {
            AddAccountView(session: session)
        }
        .alert("Credential Cleanup Incomplete", isPresented: Binding(
            get: { session.cleanupErrorMessage != nil },
            set: { if !$0 { session.cleanupErrorMessage = nil } }
        )) {
            Button("Retry Cleanup") { session.retryCredentialCleanup() }
            Button("Later", role: .cancel) { session.cleanupErrorMessage = nil }
        } message: {
            Text(session.cleanupErrorMessage ?? "Some saved credentials could not be deleted.")
        }
        // The only place foreground invalidation happens: mounted trees do
        // not re-run `task` on return, so advance the shared generation.
        .onChange(of: scenePhase, initial: true) { _, phase in
            // October may have begun or ended while the app slept.
            if phase == .active { ThemeStore.shared.refreshSeason() }
            guard phase == .active, session.phase == .signedIn else { return }
            serverSync.requestRefresh()
            #if os(tvOS)
            // Safety net: otherwise only a successful Home load publishes,
            // and one failed cold-start load leaves the shelf empty.
            TopShelfStore.publishIfEmpty(client: session.client)
            #endif
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .signedIn else { return }
            serverSync.requestRefresh()
            #if os(tvOS)
            TopShelfStore.publishIfEmpty(client: session.client)
            #endif
        }
        #if DEBUG
        .overlay(alignment: .topLeading) {
            if UserDefaults.standard.bool(forKey: "debug.serverSyncRegression") {
                VStack {
                    RegressionProbe(
                        label: "Server sync generation",
                        identifier: "server.sync.generation",
                        value: "\(serverSync.generation)"
                    )
                    RegressionProbe(
                        label: "Periodic Home refreshes",
                        identifier: "server.sync.periodic.home",
                        value: "\(serverSync.refreshCount(.home, trigger: .periodic))"
                    )
                    RegressionProbe(
                        label: "Foreground Home refreshes",
                        identifier: "server.sync.foreground.home",
                        value: "\(serverSync.refreshCount(.home, trigger: .foreground))"
                    )
                    RegressionProbe(
                        label: "Manual Home refreshes",
                        identifier: "server.sync.manual.home",
                        value: "\(serverSync.refreshCount(.home, trigger: .manual))"
                    )
                }
            }
        }
        .task {
            await session.bootstrapPublicDemoForRegressionIfRequested()
        }
        #endif
    }
}

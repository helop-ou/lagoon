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
                    regressionProbe(
                        label: "Server sync generation",
                        value: serverSync.generation,
                        identifier: "server.sync.generation"
                    )
                    regressionProbe(
                        label: "Periodic Home refreshes",
                        value: serverSync.refreshCount(.home, trigger: .periodic),
                        identifier: "server.sync.periodic.home"
                    )
                    regressionProbe(
                        label: "Foreground Home refreshes",
                        value: serverSync.refreshCount(.home, trigger: .foreground),
                        identifier: "server.sync.foreground.home"
                    )
                    regressionProbe(
                        label: "Manual Home refreshes",
                        value: serverSync.refreshCount(.home, trigger: .manual),
                        identifier: "server.sync.manual.home"
                    )
                }
            }
        }
        .task {
            await session.bootstrapPublicDemoForRegressionIfRequested()
        }
        #endif
    }

    #if DEBUG
    private func regressionProbe(label: String, value: Int, identifier: String) -> some View {
        Text(label)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue("\(value)")
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
    #endif
}

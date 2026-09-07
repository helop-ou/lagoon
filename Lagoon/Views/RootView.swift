import SwiftUI

/// Switches between onboarding and the main UI off the session phase —
/// connection states are states, not screens you navigate to.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var seerr = SeerrSessionStore()
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
            }
        }
        .animation(.easeInOut(duration: Motion.standard), value: session.phase)
        .environment(session)
        .environment(seerr)
        .environment(serverSync)
        .fullScreenCover(isPresented: Binding(
            get: { session.isAddingAccount },
            set: { session.isAddingAccount = $0 }
        )) {
            AddAccountView(session: session)
        }
        .task(id: session.activeAccount?.id) {
            await seerr.activate(for: session.activeAccount)
        }
        // Returning from the device's home screen does not re-run `onAppear`
        // or `task` on the navigation tree SwiftUI kept mounted. Advance one
        // shared generation here so each server-backed screen can reconcile
        // the state it owns (HEL-135).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, session.phase == .signedIn else { return }
            serverSync.requestRefresh()
            #if os(tvOS)
            // The Top Shelf's safety net. Publishing otherwise happens only
            // as a side effect of Home loading successfully, so one failed
            // load on a cold start left the shelf empty with nothing to retry
            // it (HEL-119).
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

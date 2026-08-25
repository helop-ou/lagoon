import SwiftUI

/// Switches between onboarding and the main UI off the session phase —
/// connection states are states, not screens you navigate to.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var seerr = SeerrSessionStore()
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
        .task(id: session.activeAccount?.id) {
            await seerr.activate(for: session.activeAccount)
        }
        #if os(tvOS)
        // The Top Shelf's safety net. Publishing otherwise happens only as a
        // side effect of Home loading successfully, so one failed load on a
        // cold start left the shelf empty with nothing to retry it. Checked
        // here because this is the one place that knows the session is up and
        // does not depend on any particular screen appearing (HEL-119).
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active, session.phase == .signedIn else { return }
            TopShelfStore.publishIfEmpty(client: session.client)
        }
        .onChange(of: session.phase) { _, phase in
            guard phase == .signedIn else { return }
            TopShelfStore.publishIfEmpty(client: session.client)
        }
        #endif
        #if DEBUG
        .task {
            await session.bootstrapPublicDemoForRegressionIfRequested()
        }
        #endif
    }
}

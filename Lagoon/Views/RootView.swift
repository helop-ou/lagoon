import SwiftUI

/// Switches between onboarding and the main UI off the session phase —
/// connection states are states, not screens you navigate to.
struct RootView: View {
    @State private var session = SessionStore()
    @State private var seerr = SeerrSessionStore()

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
        #if DEBUG
        .task {
            await session.bootstrapPublicDemoForRegressionIfRequested()
        }
        #endif
    }
}

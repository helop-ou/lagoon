import SwiftUI

/// Switches between onboarding and the main UI off the session phase —
/// connection states are states, not screens you navigate to.
struct RootView: View {
    @State private var session = SessionStore()

    var body: some View {
        ZStack {
            switch session.phase {
            case .needsServer:
                ServerConnectView()
            case .needsSignIn:
                SignInView()
            case .signedIn:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: Motion.standard), value: session.phase)
        .environment(session)
    }
}

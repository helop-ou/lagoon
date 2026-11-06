import SwiftUI

struct WelcomeView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        ZStack {
            GroundBackground()
            JellyfishSwimLayer()

            #if os(iOS)
            OnboardingColumn {
                LagoonLockup()
                    .padding(.vertical, Metrics.Space.l)
                message
                startButton
                    .buttonStyle(.glass)
                    .controlSize(.extraLarge)
                    .font(.title3.weight(.semibold))
            }
            #else
            VStack(spacing: Metrics.Space.xl) {
                LagoonLockup()
                message
                    .padding(.bottom, Metrics.Space.l)
                startButton
                    .buttonStyle(.glass)
            }
            .frame(maxWidth: Metrics.readableWidth)
            .padding(.horizontal, Metrics.screenGutter)
            #endif
        }
    }

    private var message: some View {
        VStack(spacing: Metrics.Space.m) {
            Text("Welcome to Lagoon")
                .font(.largeTitle.bold())
            Text("Watch your Jellyfin library, with a player made for it.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #if os(iOS)
            // Said before the system prompt, which the search on the next screen raises.
            Text("Next, Lagoon looks for Jellyfin servers on your network. Allow Local Network access when iOS asks.")
                .font(.callout)
                .foregroundStyle(.secondary)
            #endif
        }
        .multilineTextAlignment(.center)
    }

    private var startButton: some View {
        Button {
            session.finishWelcome()
        } label: {
            Text("Get Started")
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("welcome.start")
    }
}

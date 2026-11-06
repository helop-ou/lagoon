import SwiftUI

/// The first sign-in's one optional step. Settings keeps the full Seerr
/// setup, including custom headers and the manual sign-in paths.
struct SeerrSetupView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    /// The server answered but the Jellyfin account could not sign in to it.
    @State private var signInFailed = false
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GroundBackground()
            JellyfishSwimLayer()

            #if os(iOS)
            OnboardingColumn {
                heading
                if signInFailed {
                    continueButton
                } else {
                    OnboardingFieldGroup { addressField }
                    connectButton
                        .buttonStyle(.glass)
                        .controlSize(.extraLarge)
                        .font(.title3.weight(.semibold))
                    failure
                    notNowButton
                        .buttonStyle(.glass)
                }
            }
            #else
            ScrollView {
                VStack(spacing: Metrics.Space.l) {
                    heading
                    if signInFailed {
                        continueButton
                    } else {
                        addressField
                        connectButton
                            .buttonStyle(.glass)
                        failure
                        notNowButton
                            .buttonStyle(.glass)
                            .padding(.top, Metrics.Space.xl)
                    }
                }
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.section)
            }
            .scrollClipDisabled()
            #endif
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private var heading: some View {
        VStack(spacing: Metrics.Space.l) {
            LagoonLockup(layout: .horizontal, symbolHeight: Metrics.lockupHeaderSymbolHeight)
            Text("Do you use Seerr?")
                .font(.largeTitle.bold())
            Text(signInFailed
                 ? "Lagoon saved the Seerr server but couldn't sign in to it with your Jellyfin account. Finish signing in from Settings, under Seerr."
                 : "Connect Seerr to find new films and series and request them. You can also do this later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(signInFailed ? "seerrSetup.signInFailed" : "seerrSetup.message")
        }
        .padding(.bottom, Metrics.Space.l)
    }

    private var addressField: some View {
        TextField("Seerr server address", text: $address, prompt: Text("Seerr URL or IP"))
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("seerrSetup.address")
            #if os(iOS)
            .modifier(OnboardingField())
            .keyboardType(.URL)
            .submitLabel(.go)
            #endif
            .onSubmit(connect)
    }

    private var connectButton: some View {
        Button(action: connect) {
            if isConnecting {
                ProgressView()
            } else {
                Text("Connect")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)
        .accessibilityIdentifier("seerrSetup.connect")
    }

    @ViewBuilder
    private var failure: some View {
        if let errorMessage {
            OnboardingErrorText(errorMessage)
        }
        if seerr.localNetworkAccessDenied { LocalNetworkRecoveryView() }
    }

    private var notNowButton: some View {
        Button("Not Now") {
            connectionTask?.cancel()
            session.finishSeerrOffer()
        }
        .accessibilityIdentifier("seerrSetup.skip")
    }

    private var continueButton: some View {
        Button {
            session.finishSeerrOffer()
        } label: {
            Text("Continue")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("seerrSetup.continue")
    }

    private func connect() {
        guard !isConnecting, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isConnecting = true
        errorMessage = nil
        connectionTask = Task {
            defer { isConnecting = false }
            do {
                try await seerr.connect(to: address)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            // A cookie saved for this account may already have signed it in.
            if !seerr.isConnected {
                do {
                    try await seerr.signInUsingJellyfin(session.client)
                } catch is CancellationError {
                    return
                } catch {
                    signInFailed = true
                    return
                }
            }
            session.finishSeerrOffer()
        }
    }
}

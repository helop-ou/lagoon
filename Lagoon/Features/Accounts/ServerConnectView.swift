import SwiftUI

struct ServerConnectView: View {
    @Environment(SessionStore.self) private var session

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var localNetworkAccessDenied = false
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            GroundBackground()

            // All onboarding screens share this backdrop, so they read as one place.
            JellyfishSwimLayer()

            #if os(iOS)
            ScrollView {
                VStack(spacing: Metrics.Space.xl) {
                    VStack(spacing: Metrics.Space.l) {
                        LagoonLockup(layout: .horizontal, symbolHeight: Metrics.lockupHeaderSymbolHeight)
                        Text("Connect to your Jellyfin server")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Metrics.Space.l)

                    addressField
                    connectButton
                        .buttonStyle(.glass)
                        .controlSize(.large)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                    if localNetworkAccessDenied { LocalNetworkRecoveryView() }

                    AboutLagoonButton()
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            #else
            VStack(spacing: Metrics.Space.l) {
                LagoonLockup()
                Text("Connect to your Jellyfin server")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Metrics.Space.l)

                addressField
                connectButton
                    .buttonStyle(.glass)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                // Legal information before any account. Last, so the address
                // field keeps the initial focus.
                AboutLagoonButton()
                    .padding(.top, Metrics.Space.xl)
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, Metrics.screenGutter)
            #endif
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private var addressField: some View {
        TextField("Server address", text: $address, prompt: Text("Server URL or IP"))
            .textContentType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("server.address")
            #if os(iOS)
            .textFieldStyle(.plain)
            .frame(minHeight: Metrics.touchTarget)
            .overlay(alignment: .bottom) { Divider() }
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
        .accessibilityIdentifier("server.connect")
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        localNetworkAccessDenied = false
        connectionTask = Task {
            defer { isConnecting = false }
            do {
                try await session.connect(to: address)
            } catch is CancellationError {
            } catch ServerAddress.Failure.invalid {
                errorMessage = ServerAddress.Failure.invalid.localizedDescription
            } catch LocalNetworkAccess.Failure.denied {
                localNetworkAccessDenied = true
                errorMessage = LocalNetworkAccess.Failure.denied.localizedDescription
            } catch {
                if !Task.isCancelled { errorMessage = "Couldn't reach a Jellyfin server at that address. Check the address and network connection, then try again." }
            }
        }
    }
}

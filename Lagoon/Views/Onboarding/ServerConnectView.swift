import SwiftUI

struct ServerConnectView: View {
    @Environment(SessionStore.self) private var session

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            BrandBackground()

            // Onboarding shares one surface and one school of jellyfish, so
            // the three screens read as one place rather than three that
            // happen to use the same colours.
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
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, Metrics.screenGutter)
            #endif
        }
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
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await session.connect(to: address)
            } catch {
                errorMessage = "Couldn't reach a Jellyfin server at that address."
            }
            isConnecting = false
        }
    }
}

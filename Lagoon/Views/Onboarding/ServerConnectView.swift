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

            VStack(spacing: Metrics.Space.l) {
                LagoonLockup()
                Text("Connect to your Jellyfin server")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Metrics.Space.l)

                TextField("Server address", text: $address, prompt: Text("Server URL or IP"))
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textFieldStyle(.roundedBorder)
                    #endif
                    .onSubmit(connect)

                Button(action: connect) {
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text("Connect")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isConnecting)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 700)
            .padding(.horizontal, Metrics.screenGutter)
        }
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

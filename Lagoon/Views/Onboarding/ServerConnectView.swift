import SwiftUI

struct ServerConnectView: View {
    @Environment(SessionStore.self) private var session

    @State private var address = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            BrandBackgroundGradient()

            // Atmosphere, and only here. The brand package restricts the
            // jellyfish to "punctuation in loading, empty-state, or
            // atmospheric moments" — putting it on all three onboarding
            // screens would make it a motif instead, which is the thing it
            // says not to do. This is the app's first screen and the one with
            // room to spare.
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    LagoonJellyfishAccent()
                        // The gutter keeps it inside the TV safe area; the
                        // extra step stops it reading as pinned to the corner
                        // on a phone, where the gutter is only 20pt.
                        .padding(.trailing, Metrics.screenGutter + Metrics.Space.l)
                        .padding(.bottom, Metrics.screenGutter + Metrics.Space.l)
                }
            }

            VStack(spacing: Metrics.Space.l) {
                LagoonLockup()
                Text("Connect to your Jellyfin server")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, Metrics.Space.l)

                TextField("Server address", text: $address, prompt: Text("Enter server URL or IP"))
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

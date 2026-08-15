import SwiftUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    @State private var quickConnectAvailable = false
    @State private var quickConnectCode: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            BrandBackgroundGradient()

            ScrollView {
                VStack(spacing: 20) {
                    Text("Sign In")
                        .font(.largeTitle.bold())
                    Text(session.serverName ?? "Jellyfin")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 20)

                    TextField("Username", text: $username)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        #if os(iOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .onSubmit(signIn)

                    Button(action: signIn) {
                        if isSigningIn {
                            ProgressView()
                        } else {
                            Text("Sign In")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(username.isEmpty || isSigningIn)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    if quickConnectAvailable {
                        quickConnectSection
                            .padding(.top, 20)
                    }

                    Button("Change Server") {
                        pollTask?.cancel()
                        Task { await session.forgetServer() }
                    }
                    .buttonStyle(.glass)
                    .padding(.top, 30)
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, 60)
            }
        }
        .task {
            quickConnectAvailable = await session.quickConnectAvailable()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var quickConnectSection: some View {
        VStack(spacing: 14) {
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let quickConnectCode {
                Text(quickConnectCode)
                    .font(.system(size: 42, weight: .bold, design: .monospaced))
                    .tracking(6)
                Text("Enter this code under Quick Connect in any signed-in Jellyfin app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
            } else {
                Button("Sign in with Quick Connect") {
                    startQuickConnect()
                }
                .buttonStyle(.glass)
            }
        }
    }

    private func signIn() {
        guard !isSigningIn, !username.isEmpty else { return }
        isSigningIn = true
        errorMessage = nil
        Task {
            do {
                try await session.signIn(username: username, password: password)
            } catch {
                errorMessage = error.localizedDescription
            }
            isSigningIn = false
        }
    }

    private func startQuickConnect() {
        errorMessage = nil
        pollTask = Task {
            do {
                let quickConnect = try await session.startQuickConnect()
                quickConnectCode = quickConnect.code
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if try await session.pollQuickConnect(secret: quickConnect.secret) {
                        return
                    }
                }
            } catch is CancellationError {
            } catch {
                errorMessage = "Quick Connect expired — try again."
                quickConnectCode = nil
            }
        }
    }
}

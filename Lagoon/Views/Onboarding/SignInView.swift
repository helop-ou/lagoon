import SwiftUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    @State private var quickConnectAvailable = false
    @State private var quickConnectCode: String?
    @State private var isStartingQuickConnect = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            BrandBackground()
            JellyfishSwimLayer()

            ScrollView {
                VStack(spacing: Metrics.Space.l) {
                    LagoonLockup(
                        layout: .horizontal,
                        symbolHeight: Metrics.lockupHeaderSymbolHeight
                    )
                    Text("Sign In")
                        .font(.largeTitle.bold())
                    Text(session.serverName ?? "Jellyfin")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, Metrics.Space.l)

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
                    .buttonStyle(.glass)
                    .disabled(username.isEmpty || isSigningIn)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    if quickConnectAvailable {
                        quickConnectSection
                            .padding(.top, Metrics.Space.l)
                    }

                    Button("Change Server") {
                        pollTask?.cancel()
                        Task { await session.forgetServer() }
                    }
                    .buttonStyle(.glass)
                    .padding(.top, Metrics.Space.xl)
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.section)
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
        VStack(spacing: Metrics.Space.m) {
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let quickConnectCode {
                Text(quickConnectCode)
                    .font(Typography.quickConnectCode)
                    .tracking(6)
                Text("Enter this code under Quick Connect in any signed-in Jellyfin app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
            } else {
                Button {
                    startQuickConnect()
                } label: {
                    if isStartingQuickConnect {
                        ProgressView()
                    } else {
                        Text("Sign in with Quick Connect")
                    }
                }
                .buttonStyle(.glass)
                .disabled(isStartingQuickConnect)
            }
        }
    }

    private func signIn() {
        guard !isSigningIn, !username.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
        quickConnectCode = nil
        isStartingQuickConnect = false
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
        guard pollTask == nil, !isStartingQuickConnect else { return }
        isStartingQuickConnect = true
        errorMessage = nil
        pollTask = Task {
            defer {
                isStartingQuickConnect = false
                pollTask = nil
            }
            do {
                let quickConnect = try await session.startQuickConnect()
                try Task.checkCancellation()
                quickConnectCode = quickConnect.code
                isStartingQuickConnect = false
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if try await session.pollQuickConnect(secret: quickConnect.secret) {
                        return
                    }
                }
            } catch is CancellationError {
                quickConnectCode = nil
            } catch {
                errorMessage = "Quick Connect expired — try again."
                quickConnectCode = nil
            }
        }
    }
}

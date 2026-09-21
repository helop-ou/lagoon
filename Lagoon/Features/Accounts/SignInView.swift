import SwiftUI

struct SignInView: View {
    @Environment(SessionStore.self) private var session
    var changeServerTitle: LocalizedStringKey = "Change Server"

    @State private var username = ""
    @State private var password = ""
    @State private var isSigningIn = false
    @State private var errorMessage: String?

    @State private var quickConnectAvailable = false
    @State private var quickConnectCode: String?
    @State private var isStartingQuickConnect = false
    @State private var pollTask: Task<Void, Never>?

    #if os(iOS)
    private enum Field { case username, password }
    @FocusState private var focusedField: Field?
    #endif

    var body: some View {
        ZStack {
            GroundBackground()
            JellyfishSwimLayer()

            #if os(iOS)
            touchForm
            #else
            ScrollView {
                VStack(spacing: Metrics.Space.l) {
                    heading
                    usernameField
                    passwordField
                    signInButton
                        .buttonStyle(.glass)

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

                    changeServerButton
                        .buttonStyle(.glass)
                        .padding(.top, Metrics.Space.xl)

                    // Last in the column, so the username field keeps the
                    // initial focus and signing in stays the obvious path.
                    AboutLagoonButton()
                        .padding(.top, Metrics.Space.l)
                }
                .frame(maxWidth: 700)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.section)
            }
            #endif
        }
        .task {
            if let account = session.reauthenticationAccount {
                username = account.userName ?? ""
            }
            quickConnectAvailable = await session.quickConnectAvailable()
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var heading: some View {
        VStack(spacing: Metrics.Space.l) {
            LagoonLockup(layout: .horizontal, symbolHeight: Metrics.lockupHeaderSymbolHeight)
            Text("Sign In")
                .font(.largeTitle.bold())
            Text(session.serverName ?? session.client.serverURL?.host() ?? "Jellyfin")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = session.client.serverURL {
                ServerConnectionInfoView(url: url)
            }
            if session.reauthenticationAccount != nil {
                Text("Your session ended. Sign in again to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("signin.sessionExpired")
                if session.accounts.count > 1 {
                    Button("Choose Another Account") { session.showAccountPicker() }
                        .accessibilityIdentifier("signin.chooseAccount")
                }
            }
        }
        .padding(.bottom, Metrics.Space.l)
    }

    private var usernameField: some View {
        TextField("Username", text: $username)
            .textContentType(.username)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityIdentifier("signin.username")
            #if os(iOS)
            .textFieldStyle(.plain)
            .frame(minHeight: Metrics.touchTarget)
            .overlay(alignment: .bottom) { Divider() }
            .focused($focusedField, equals: .username)
            .submitLabel(.next)
            .onSubmit { focusedField = .password }
            #endif
    }

    private var passwordField: some View {
        SecureField("Password", text: $password)
            .textContentType(.password)
            .accessibilityIdentifier("signin.password")
            #if os(iOS)
            .textFieldStyle(.plain)
            .frame(minHeight: Metrics.touchTarget)
            .overlay(alignment: .bottom) { Divider() }
            .focused($focusedField, equals: .password)
            .submitLabel(.go)
            #endif
            .onSubmit(signIn)
    }

    private var signInButton: some View {
        Button(action: signIn) {
            if isSigningIn {
                ProgressView()
            } else {
                Text("Sign In")
                    .frame(maxWidth: .infinity)
            }
        }
        .disabled(username.isEmpty || isSigningIn)
        .accessibilityIdentifier("signin.submit")
    }

    private var changeServerButton: some View {
        Button(changeServerTitle) {
            pollTask?.cancel()
            #if os(iOS)
            focusedField = nil
            #endif
            Task { await session.forgetServer() }
        }
        .accessibilityIdentifier("signin.changeServer")
    }

    #if os(iOS)
    private var touchForm: some View {
        ScrollView {
            VStack(spacing: Metrics.Space.xl) {
                heading

                VStack(spacing: Metrics.Space.l) {
                    usernameField
                    passwordField
                }

                signInButton
                    .buttonStyle(.glass)
                    .controlSize(.large)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }

                if quickConnectAvailable {
                    quickConnectSection
                }

                changeServerButton
                    .buttonStyle(.plain)
                    .frame(minHeight: Metrics.touchTarget)

                AboutLagoonButton()
            }
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.screenGutter)
            .padding(.vertical, Metrics.Space.xl)
        }
        .scrollDismissesKeyboard(.interactively)
    }
    #endif

    private var quickConnectSection: some View {
        VStack(spacing: Metrics.Space.m) {
            Text("or")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if let quickConnectCode {
                quickConnectDetails(code: quickConnectCode)
            } else {
                quickConnectButton
                    .buttonStyle(.glass)
            }
        }
    }

    private func quickConnectDetails(code: String) -> some View {
        VStack(spacing: Metrics.Space.m) {
            Text(code)
                .font(Typography.quickConnectCode)
                .tracking(6)
            Text("Enter this code under Quick Connect in any signed-in Jellyfin app.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView()
        }
    }

    private var quickConnectButton: some View {
        Button(action: startQuickConnect) {
            if isStartingQuickConnect {
                ProgressView()
            } else {
                Text("Sign in with Quick Connect")
            }
        }
        .disabled(isStartingQuickConnect)
    }

    private func signIn() {
        guard !isSigningIn, !username.isEmpty else { return }
        #if os(iOS)
        focusedField = nil
        #endif
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

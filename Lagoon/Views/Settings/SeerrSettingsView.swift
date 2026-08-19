import SwiftUI

struct SeerrSettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(SeerrSessionStore.self) private var seerr

    @State private var serverAddress = ""
    @State private var username = ""
    @State private var password = ""
    @State private var quickConnectCode: String?
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        Group {
            #if os(tvOS)
            TVSettingsPage(
                "Seerr",
                description: "Connect this Jellyfin user to Seerr for discovery, requests, and permission-based moderation. Lagoon never stores your Jellyfin password."
            ) {
                tvContent
            }
            #else
            touchContent
                .navigationTitle("Seerr")
            #endif
        }
        .task(id: session.activeAccount?.id) {
            serverAddress = seerr.suggestedServerAddress(for: session.activeAccount)
        }
        .onDisappear { pollTask?.cancel() }
    }

    #if os(tvOS)
    @ViewBuilder
    private var tvContent: some View {
        TVSettingsSection(
            "Server",
            footer: "Seerr and Jellyseerr instances using the standard /api/v1 API are supported."
        ) {
            if let url = seerr.configuredURL {
                infoRow("Address", value: url.host() ?? url.absoluteString)
                if let version = seerr.status?.version {
                    infoRow("Version", value: version)
                }
            } else {
                TextField("Seerr server address", text: $serverAddress)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.seerr.server")

                Button(action: connect) {
                    workingLabel("Connect")
                }
                .buttonStyle(.glass)
                .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                .accessibilityIdentifier("settings.seerr.connect")
            }
        }

        if seerr.isConfigured {
            TVSettingsSection("Jellyfin Account") {
                if let user = seerr.user {
                    infoRow("User", value: user.name)
                    infoRow("Access", value: permissionSummary(for: user))
                    Button("Disconnect Seerr Account") {
                        Task { await seerr.disconnect() }
                    }
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("settings.seerr.disconnect")
                } else {
                    authenticationControls
                }
            }

            TVSettingsSection("Server Actions") {
                Button("Change Seerr Server", role: .destructive) {
                    pollTask?.cancel()
                    Task {
                        await seerr.forgetServer()
                        serverAddress = seerr.suggestedServerAddress(for: session.activeAccount)
                        quickConnectCode = nil
                    }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.seerr.changeServer")
            }
        }

        errorLabel
    }
    #endif

    #if !os(tvOS)
    private var touchContent: some View {
        Form {
            Section("Server") {
                if let url = seerr.configuredURL {
                    LabeledContent("Address", value: url.host() ?? url.absoluteString)
                    if let version = seerr.status?.version {
                        LabeledContent("Version", value: version)
                    }
                } else {
                    TextField("Seerr server address", text: $serverAddress)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Connect", action: connect)
                        .disabled(serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
                }
            }

            if seerr.isConfigured {
                Section("Jellyfin Account") {
                    if let user = seerr.user {
                        LabeledContent("User", value: user.name)
                        LabeledContent("Access", value: permissionSummary(for: user))
                        Button("Disconnect Seerr Account", role: .destructive) {
                            Task { await seerr.disconnect() }
                        }
                    } else {
                        authenticationControls
                    }
                }

                Section {
                    Button("Change Seerr Server", role: .destructive) {
                        pollTask?.cancel()
                        Task {
                            await seerr.forgetServer()
                            serverAddress = seerr.suggestedServerAddress(for: session.activeAccount)
                            quickConnectCode = nil
                        }
                    }
                }
            }

            if let errorMessage = errorMessage ?? seerr.errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private var authenticationControls: some View {
        if let quickConnectCode {
            VStack(spacing: Metrics.Space.m) {
                Text(quickConnectCode)
                    .font(Typography.quickConnectCode)
                    .tracking(6)
                    .accessibilityIdentifier("settings.seerr.quickConnectCode")
                Text("Enter this code under Quick Connect in Jellyfin. Lagoon will finish signing in automatically.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, Metrics.Space.l)
        } else {
            Button("Connect with Jellyfin Quick Connect", action: startQuickConnect)
                #if os(tvOS)
                .buttonStyle(.glass)
                #endif
                .disabled(isWorking)
                .accessibilityIdentifier("settings.seerr.quickConnect")

            Text("Or sign in once for older Jellyseerr servers")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, Metrics.Space.l)

            TextField("Jellyfin username", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("settings.seerr.username")
            SecureField("Jellyfin password", text: $password)
                .textContentType(.password)
                .accessibilityIdentifier("settings.seerr.password")
            Button(action: passwordSignIn) {
                workingLabel("Sign In")
            }
            #if os(tvOS)
            .buttonStyle(.glass)
            #endif
            .disabled(username.isEmpty || isWorking)
            .accessibilityIdentifier("settings.seerr.signIn")
        }
    }

    @ViewBuilder
    private var errorLabel: some View {
        #if os(tvOS)
        if let errorMessage = errorMessage ?? seerr.errorMessage {
            Text(errorMessage)
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("settings.seerr.error")
        }
        #endif
    }

    #if os(tvOS)
    private func infoRow(_ title: LocalizedStringKey, value: String) -> some View {
        TVSettingsActionLabel(title, value: value)
            .padding(.horizontal, Metrics.Space.l)
            .frame(minHeight: 64)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }
    #endif

    private func workingLabel(_ title: LocalizedStringKey) -> some View {
        HStack {
            Text(title)
            if isWorking { ProgressView() }
        }
        .frame(maxWidth: .infinity)
    }

    private func connect() {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await seerr.connect(to: serverAddress)
                serverAddress = seerr.configuredURL?.absoluteString ?? serverAddress
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func startQuickConnect() {
        guard pollTask == nil, !isWorking else { return }
        isWorking = true
        errorMessage = nil
        pollTask = Task {
            defer {
                isWorking = false
                pollTask = nil
            }
            do {
                let result = try await seerr.startQuickConnect()
                try Task.checkCancellation()
                quickConnectCode = result.code
                for _ in 0..<150 {
                    try await Task.sleep(for: .seconds(2))
                    if try await seerr.pollQuickConnect(secret: result.secret) {
                        quickConnectCode = nil
                        return
                    }
                }
                throw SeerrError.server(408, "Quick Connect expired. Start it again for a new code.")
            } catch is CancellationError {
                quickConnectCode = nil
            } catch {
                errorMessage = error.localizedDescription
                quickConnectCode = nil
            }
        }
    }

    private func passwordSignIn() {
        guard !username.isEmpty, !isWorking else { return }
        let submittedUsername = username
        let submittedPassword = password
        password = ""
        pollTask?.cancel()
        quickConnectCode = nil
        isWorking = true
        errorMessage = nil
        Task {
            do {
                try await seerr.signIn(username: submittedUsername, password: submittedPassword)
            } catch {
                errorMessage = error.localizedDescription
            }
            isWorking = false
        }
    }

    private func permissionSummary(for user: SeerrUser) -> String {
        if user.canManageRequests { return "Request Manager" }
        let movie = user.canRequest(.movie)
        let shows = user.canRequest(.tv)
        if movie && shows { return "Movies & Shows" }
        if movie { return "Movies" }
        if shows { return "Shows" }
        return "View Only"
    }
}

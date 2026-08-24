import SwiftUI

/// Account and key management for the direct subtitle provider (HEL-92).
///
/// Nothing here is required to use Lagoon: with a Jellyfin account that has
/// Subtitle Management the server route is used and this screen never comes
/// up. It exists for the accounts Jellyfin will not serve, which on a shared
/// server is most of them.
struct OpenSubtitlesSettingsView: View {
    @State private var account = OpenSubtitlesAccountStore.shared
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""

    var body: some View {
        #if os(tvOS)
        tvBody
        #else
        phoneBody
        #endif
    }

    // MARK: - tvOS

    #if os(tvOS)
    private var tvBody: some View {
        TVSettingsPage(
            "OpenSubtitles",
            backTitle: "Subtitles",
            description: "A direct subtitle source for Jellyfin accounts that may not manage subtitles. Downloads go straight into the player and are never uploaded to your Jellyfin library.",
            titleLineLimit: 1
        ) {
            TVSettingsSection(
                "Provider Key",
                footer: "OpenSubtitles requires an application key. Register one free at opensubtitles.com under API Consumers, then paste it here. Searching costs nothing; downloads are limited per day."
            ) {
                TVSettingsActionLabel("Status", value: keyStatus)

                TextField("OpenSubtitles API key", text: $apiKey)
                    .accessibilityIdentifier("settings.openSubtitles.apiKey")

                Button("Save Key") { saveKey() }
                    .buttonStyle(.glass)
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)

                if account.apiKeyOverride != nil {
                    Button("Remove Saved Key", role: .destructive) {
                        account.setAPIKeyOverride(nil)
                        apiKey = ""
                    }
                    .buttonStyle(.glass)
                }
            }

            TVSettingsSection(
                "Account",
                footer: "Optional. Without an account Lagoon can still download a few subtitles a day; signing in raises that allowance."
            ) {
                TVSettingsActionLabel(
                    "Signed In As",
                    value: account.accountName ?? String(localized: "Not signed in")
                )

                if account.isSignedIn {
                    Button("Sign Out", role: .destructive) { account.signOut() }
                        .buttonStyle(.glass)
                } else {
                    TextField("OpenSubtitles username", text: $username)
                        .accessibilityIdentifier("settings.openSubtitles.username")

                    SecureField("OpenSubtitles password", text: $password)
                        .accessibilityIdentifier("settings.openSubtitles.password")

                    Button(action: signIn) {
                        if account.isWorking {
                            ProgressView()
                        } else {
                            Text("Sign In")
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(!canSignIn)
                }

                if let message = account.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear(perform: load)
    }
    #endif

    // MARK: - iOS

    #if !os(tvOS)
    private var phoneBody: some View {
        Form {
            Section {
                LabeledContent("Status", value: keyStatus)
                TextField("API key", text: $apiKey)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button("Save Key") { saveKey() }
                    .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if account.apiKeyOverride != nil {
                    Button("Remove Saved Key", role: .destructive) {
                        account.setAPIKeyOverride(nil)
                        apiKey = ""
                    }
                }
            } header: {
                Text("Provider Key")
            } footer: {
                Text("OpenSubtitles requires an application key. Register one free at opensubtitles.com under API Consumers. Searching costs nothing; downloads are limited per day.")
            }

            Section {
                LabeledContent("Signed In As", value: account.accountName ?? "Not signed in")
                if account.isSignedIn {
                    Button("Sign Out", role: .destructive) { account.signOut() }
                } else {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    SecureField("Password", text: $password)
                    Button("Sign In", action: signIn)
                        .disabled(!canSignIn)
                }
                if let message = account.lastErrorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Account")
            } footer: {
                Text("Optional. Without an account Lagoon can still download a few subtitles a day; signing in raises that allowance. Downloads go straight into the player and are never uploaded to Jellyfin.")
            }
        }
        .navigationTitle("OpenSubtitles")
        .onAppear(perform: load)
    }
    #endif

    // MARK: - Shared

    private var keyStatus: String {
        if account.isConfigured {
            return account.apiKeyOverride != nil
                ? String(localized: "Saved on this device")
                : String(localized: "Built in")
        }
        return String(localized: "Missing")
    }

    private var canSignIn: Bool {
        account.isConfigured
            && !account.isWorking
            && !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
    }

    private func load() {
        account.reloadConfiguration()
        apiKey = account.apiKeyOverride ?? ""
    }

    private func saveKey() {
        account.setAPIKeyOverride(apiKey)
    }

    private func signIn() {
        let user = username
        let secret = password
        Task {
            await account.signIn(username: user, password: secret)
            if account.isSignedIn {
                username = ""
                password = ""
            }
        }
    }
}

import Foundation
import Observation

/// Owns the one `OpenSubtitlesClient` shared by Settings and the player, and
/// the credentials behind it. The token lives in the keychain alongside the
/// Jellyfin ones; the account name is only a display label (HEL-92).
///
/// Signing in is optional by design: search needs no account at all and
/// anonymous downloads are allowed, just fewer. The prompt is therefore
/// deferred until the allowance actually runs out, which on tvOS matters —
/// on-screen text entry is the most expensive thing the UI can ask for.
@MainActor
@Observable
final class OpenSubtitlesAccountStore {
    static let shared = OpenSubtitlesAccountStore()

    private(set) var accountName: String?
    private(set) var isWorking = false
    private(set) var lastErrorMessage: String?

    @ObservationIgnored let client: OpenSubtitlesClient
    @ObservationIgnored private let defaults: UserDefaults

    private static let keychainAccount = "lagoon.opensubtitles.token"
    private static let accountNameKey = "subtitles.openSubtitlesAccountName"

    init(
        client: OpenSubtitlesClient = OpenSubtitlesClient(),
        defaults: UserDefaults = .standard
    ) {
        self.client = client
        self.defaults = defaults
        reloadConfiguration()
        restore()
    }

    var isConfigured: Bool { client.isConfigured }
    var isSignedIn: Bool { accountName != nil }

    /// Picked up whenever the key may have changed — a build with the value
    /// compiled in, or one pasted into Settings.
    func reloadConfiguration() {
        client.configure(apiKey: OpenSubtitlesConfiguration.apiKey(defaults: defaults))
    }

    private func restore() {
        let name = defaults.string(forKey: Self.accountNameKey)
        let token = KeychainStore.string(for: Self.keychainAccount)
        guard let name, let token else { return }
        accountName = name
        client.restoreSession(token: token, accountName: name)
    }

    func signIn(username: String, password: String) async {
        guard !isWorking else { return }
        isWorking = true
        lastErrorMessage = nil
        defer { isWorking = false }
        do {
            let name = try await client.signIn(username: username, password: password)
            // A token that cannot be stored would silently stop working after
            // the next launch, so treat that as a failed sign-in.
            try KeychainStore.set(client.token ?? "", for: Self.keychainAccount)
            defaults.set(name, forKey: Self.accountNameKey)
            accountName = name
        } catch {
            client.signOut()
            accountName = nil
            lastErrorMessage = OpenSubtitlesError.classify(error).localizedDescription
        }
    }

    func signOut() {
        client.signOut()
        try? KeychainStore.delete(Self.keychainAccount)
        defaults.removeObject(forKey: Self.accountNameKey)
        accountName = nil
        lastErrorMessage = nil
    }

    /// Stores a consumer key entered by hand. Registering an application at
    /// opensubtitles.com is the only way to obtain one, and it is per-app
    /// rather than per-user, so a build can also carry it in Info.plist.
    func setAPIKeyOverride(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            defaults.set(trimmed, forKey: OpenSubtitlesConfiguration.defaultsKey)
        } else {
            defaults.removeObject(forKey: OpenSubtitlesConfiguration.defaultsKey)
        }
        reloadConfiguration()
    }

    var apiKeyOverride: String? {
        defaults.string(forKey: OpenSubtitlesConfiguration.defaultsKey)
    }
}

import Foundation

/// Forgetting is local and immediate even if Keychain is temporarily locked.
/// Pending removals quarantine credentials until deletion succeeds; adding the
/// same identity again must finish cleanup before saving its replacement token.
@MainActor
final class AccountLocalData {
    let defaults: UserDefaults
    let credentials: any AccountCredentialStorage
    private static let pendingKey = "accounts.pendingCredentialRemoval"
    private static let pendingCookiesKey = "seerr.pendingCookieRemoval"

    init(defaults: UserDefaults, credentials: any AccountCredentialStorage) {
        self.defaults = defaults
        self.credentials = credentials
    }

    var pendingAccountIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.pendingKey) }
    }

    var pendingCookieKeys: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.pendingCookiesKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.pendingCookiesKey) }
    }

    func removeSeerrCookie(_ key: String) throws {
        pendingCookieKeys.insert(key)
        try credentials.delete(key)
        pendingCookieKeys.remove(key)
    }

    func saveSeerrCookie(_ cookie: String, for key: String) throws {
        try credentials.set(cookie, for: key)
        guard credentials.string(for: key) == cookie else { throw KeychainStore.StoreError.verificationFailed }
        pendingCookieKeys.remove(key)
    }

    func beginRemoval(accountID: String) {
        pendingAccountIDs.insert(accountID)
        for prefix in ["libraries.", "subtitles.preferences.", "playback.trackPreferences.",
                       "home.sectionPreferences.", "search.recents."] {
            defaults.removeObject(forKey: prefix + accountID)
        }
    }

    func finishRemoval(accountID: String) throws {
        guard pendingAccountIDs.contains(accountID) else { return }
        // Enumerate before deleting, so a failure cannot falsely report that
        // the cookies were removed. The persistent quarantine remains on error.
        let cookiePrefix = "seerr.cookie:\(accountID)|"
        let names = try credentials.accountNames().filter { $0.hasPrefix(cookiePrefix) }
        var failure: Error?
        for name in ["token:\(accountID)"] + names {
            do { try credentials.delete(name) } catch { failure = error }
        }
        if let failure { throw failure }
        pendingCookieKeys = pendingCookieKeys.filter { !$0.hasPrefix(cookiePrefix) }
        pendingAccountIDs.remove(accountID)
    }

    func retryPendingRemovals() throws {
        var failure: Error?
        for accountID in pendingAccountIDs {
            do { try finishRemoval(accountID: accountID) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    static func seerrServerKey(_ account: StoredAccount) -> String { "seerr.server.\(account.serverURL.absoluteString)" }
    static func seerrCookieKey(_ account: StoredAccount, serverURL: URL) -> String {
        "seerr.cookie:\(account.id)|\(serverURL.absoluteString)"
    }
}

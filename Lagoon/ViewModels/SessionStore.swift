import Foundation
import Observation

/// Owns the connection lifecycle: which server, which user, which token.
/// The server address and user identity live in UserDefaults; the access
/// token and device id live in the keychain.
@Observable
final class SessionStore {
    enum Phase {
        case needsServer
        case needsSignIn
        /// More than one account is remembered and none is active — the
        /// "who's watching?" picker (HEL-38).
        case choosingAccount
        case signedIn
    }

    private(set) var phase: Phase = .needsServer
    private(set) var serverName: String?
    private(set) var userName: String?
    /// Every remembered server+user pair, in the order they were added.
    private(set) var accounts: [StoredAccount] = []
    private(set) var activeAccount: StoredAccount?
    let client: JellyfinClient

    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        /// The server being connected to *right now* — the sign-in screen's
        /// subject. Distinct from the accounts list, which only gains an
        /// entry once credentials actually work.
        static let serverURL = "server.url"
        static let serverName = "server.name"
        static let accounts = "accounts"
        static let activeAccountId = "session.activeAccountId"
        /// Single-slot layout, pre-HEL-38. Read once by the migration.
        static let legacyUserId = "session.userId"
        static let legacyUserName = "session.userName"
    }

    private enum KeychainKey {
        /// Single-slot layout, pre-HEL-38. Read once by the migration.
        static let legacyAccessToken = "accessToken"
        static let deviceId = "deviceId"
    }

    init() {
        let deviceId: String
        if let stored = KeychainStore.string(for: KeychainKey.deviceId) {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString
            KeychainStore.set(deviceId, for: KeychainKey.deviceId)
        }
        client = JellyfinClient(deviceId: deviceId)
        restore()
    }

    private func restore() {
        migrateLegacySessionIfNeeded()
        accounts = loadAccounts()

        // Resume the last account rather than asking every launch. A single
        // profile shouldn't have to be picked before every session; the
        // picker is reachable from Settings whenever it is wanted.
        if let id = defaults.string(forKey: DefaultsKey.activeAccountId),
           let account = accounts.first(where: { $0.id == id }),
           activate(account) {
            return
        }

        if !accounts.isEmpty {
            phase = .choosingAccount
            return
        }

        // No accounts: fall back to whatever server was mid-connect, so an
        // interrupted sign-in resumes where it left off.
        guard let urlString = defaults.string(forKey: DefaultsKey.serverURL),
              let url = URL(string: urlString) else {
            phase = .needsServer
            return
        }
        client.configure(serverURL: url)
        serverName = defaults.string(forKey: DefaultsKey.serverName)
        phase = .needsSignIn
    }

    // MARK: - Accounts (HEL-38)

    /// Points the client at a remembered account. Fails only when its token
    /// has gone — a cleared keychain, or a session revoked server-side.
    @discardableResult
    private func activate(_ account: StoredAccount) -> Bool {
        guard let token = KeychainStore.string(for: account.keychainAccount) else { return false }
        client.configure(serverURL: account.serverURL)
        client.activateSession(token: token, userId: account.userId)
        activeAccount = account
        serverName = account.serverName
        userName = account.userName
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)
        phase = .signedIn
        return true
    }

    /// Switches to another remembered account without re-entering
    /// credentials. Every Jellyfin call is user-scoped, so Continue
    /// Watching and the rest follow on their own.
    func switchTo(_ account: StoredAccount) {
        client.clearSession()
        guard !activate(account) else { return }
        // The account outlived its token. Send them to sign-in for *that*
        // server rather than leaving a dead entry in the picker.
        client.configure(serverURL: account.serverURL)
        serverName = account.serverName
        userName = nil
        activeAccount = nil
        defaults.set(account.serverURL.absoluteString, forKey: DefaultsKey.serverURL)
        defaults.set(account.serverName, forKey: DefaultsKey.serverName)
        phase = .needsSignIn
    }

    func showAccountPicker() {
        phase = .choosingAccount
    }

    /// Starts adding a server+user alongside the ones already remembered.
    func addAccount() {
        client.clearSession()
        activeAccount = nil
        serverName = nil
        userName = nil
        defaults.removeObject(forKey: DefaultsKey.serverURL)
        defaults.removeObject(forKey: DefaultsKey.serverName)
        phase = .needsServer
    }

    /// Forgets an account from the picker, token and all.
    func remove(_ account: StoredAccount) {
        KeychainStore.delete(account.keychainAccount)
        save(accounts: accounts.filter { $0.id != account.id })
        if activeAccount?.id == account.id {
            activeAccount = nil
            defaults.removeObject(forKey: DefaultsKey.activeAccountId)
        }
        if accounts.isEmpty { phase = .needsServer }
    }

    private func loadAccounts() -> [StoredAccount] {
        guard let data = defaults.data(forKey: DefaultsKey.accounts) else { return [] }
        return (try? JSONDecoder().decode([StoredAccount].self, from: data)) ?? []
    }

    private func save(accounts list: [StoredAccount]) {
        accounts = list
        defaults.set(try? JSONEncoder().encode(list), forKey: DefaultsKey.accounts)
    }

    /// One-time move off the single-slot layout. Without it the upgrade
    /// silently signs every existing install out, which is the one thing
    /// this feature must not do.
    private func migrateLegacySessionIfNeeded() {
        guard defaults.data(forKey: DefaultsKey.accounts) == nil,
              let urlString = defaults.string(forKey: DefaultsKey.serverURL),
              let url = URL(string: urlString),
              let userId = defaults.string(forKey: DefaultsKey.legacyUserId),
              let token = KeychainStore.string(for: KeychainKey.legacyAccessToken) else { return }

        let account = StoredAccount(
            serverURL: url,
            serverName: defaults.string(forKey: DefaultsKey.serverName),
            userId: userId,
            userName: defaults.string(forKey: DefaultsKey.legacyUserName)
        )
        KeychainStore.set(token, for: account.keychainAccount)
        save(accounts: [account])
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)

        KeychainStore.delete(KeychainKey.legacyAccessToken)
        defaults.removeObject(forKey: DefaultsKey.legacyUserId)
        defaults.removeObject(forKey: DefaultsKey.legacyUserName)
    }

    // MARK: - Connect

    func connect(to input: String) async throws {
        var lastError: Error = JellyfinError.invalidServerURL
        for url in Self.candidateURLs(for: input) {
            do {
                let info = try await JellyfinClient.fetchPublicInfo(at: url)
                client.configure(serverURL: url)
                serverName = info.serverName
                defaults.set(url.absoluteString, forKey: DefaultsKey.serverURL)
                defaults.set(info.serverName, forKey: DefaultsKey.serverName)
                phase = .needsSignIn
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Expands what the user typed into URLs worth probing. Schemeless input
    /// tries https and http, plus Jellyfin's default port 8096 when none was
    /// given; LAN-looking hosts probe http first so https can't stall them.
    nonisolated static func candidateURLs(for input: String) -> [URL] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return [] }

        if trimmed.contains("://") {
            return URL(string: trimmed).map { [$0] } ?? []
        }

        let host = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        let hasPort = host.split(separator: ":").count == 2
        let looksLocal = host.hasSuffix(".local")
            || host.split(separator: ":").first.map { $0.allSatisfy { $0.isNumber || $0 == "." } } == true

        var strings = looksLocal ? ["http://\(trimmed)"] : ["https://\(trimmed)", "http://\(trimmed)"]
        if !hasPort {
            strings.append("http://\(trimmed):8096")
        }
        if looksLocal {
            strings.append("https://\(trimmed)")
        }
        return strings.compactMap { URL(string: $0) }
    }

    // MARK: - Sign-in

    func signIn(username: String, password: String) async throws {
        let result = try await client.authenticateByName(username: username, password: password)
        completeSignIn(with: result)
    }

    func quickConnectAvailable() async -> Bool {
        (try? await client.quickConnectEnabled()) ?? false
    }

    func startQuickConnect() async throws -> QuickConnectResult {
        try await client.initiateQuickConnect()
    }

    /// One poll step; returns true once the user has approved the code
    /// on another device and the session is active.
    func pollQuickConnect(secret: String) async throws -> Bool {
        let state = try await client.quickConnectState(secret: secret)
        guard state.authenticated else { return false }
        let result = try await client.authenticateWithQuickConnect(secret: secret)
        completeSignIn(with: result)
        return true
    }

    private func completeSignIn(with result: AuthenticationResult) {
        guard let url = client.serverURL else { return }
        let account = StoredAccount(
            serverURL: url,
            serverName: serverName,
            userId: result.user.id,
            userName: result.user.name
        )
        KeychainStore.set(result.accessToken, for: account.keychainAccount)
        // Re-signing in as someone already remembered refreshes that entry
        // rather than duplicating them.
        save(accounts: accounts.filter { $0.id != account.id } + [account])

        client.activateSession(token: result.accessToken, userId: result.user.id)
        activeAccount = account
        userName = result.user.name
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)
        phase = .signedIn
    }

    // MARK: - Sign-out

    /// Signs out and *forgets* the active account — the token is revoked
    /// server-side, so keeping the entry would only offer a dead session.
    /// Any other remembered account survives, and the picker takes over.
    func signOut() async {
        try? await client.logout()
        client.clearSession()
        if let account = activeAccount {
            KeychainStore.delete(account.keychainAccount)
            save(accounts: accounts.filter { $0.id != account.id })
        }
        activeAccount = nil
        userName = nil
        defaults.removeObject(forKey: DefaultsKey.activeAccountId)
        phase = accounts.isEmpty ? .needsSignIn : .choosingAccount
    }

    func forgetServer() async {
        await signOut()
        defaults.removeObject(forKey: DefaultsKey.serverURL)
        defaults.removeObject(forKey: DefaultsKey.serverName)
        serverName = nil
        phase = .needsServer
    }
}

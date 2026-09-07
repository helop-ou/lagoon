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
    private(set) var activeAccount: StoredAccount? {
        didSet { synchronizeAccountContext() }
    }
    /// Retained identity for reauthentication; it has no active credential.
    private(set) var reauthenticationAccount: StoredAccount?
    var isAddingAccount = false
    let client: JellyfinClient
    let seerr: SeerrSessionStore
    let recentSearches: RecentSearchStore
    var cleanupErrorMessage: String?

    private let defaults: UserDefaults
    private let isAccountDraft: Bool
    private let sessionConfiguration: URLSessionConfiguration
    private let localData: AccountLocalData
    private let credentials: any AccountCredentialStorage
    private var draftCancelled = false
    private var pendingAuthentication: AuthenticationResult?
    private var connectionGeneration = 0

    private enum DefaultsKey {
        /// The server being connected to *right now* — the sign-in screen's
        /// subject. Distinct from the accounts list, which only gains an
        /// entry once credentials actually work.
        static let serverURL = "server.url"
        static let serverName = "server.name"
        static let accounts = "accounts"
        static let activeAccountId = "session.activeAccountId"
        static let expiredAccounts = "session.expiredAccountIds"
        /// Single-slot layout, pre-HEL-38. Read once by the migration.
        static let legacyUserId = "session.userId"
        static let legacyUserName = "session.userName"
    }

    private enum KeychainKey {
        /// Single-slot layout, pre-HEL-38. Read once by the migration.
        static let legacyAccessToken = "accessToken"
        static let deviceId = "deviceId"
    }

    init(accountDraft: Bool = false, defaults: UserDefaults = .standard,
         sessionConfiguration: URLSessionConfiguration = .default,
         credentials: any AccountCredentialStorage = SystemAccountCredentials(),
         seerrClient: SeerrClient? = nil) {
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.credentials = credentials
        let localData = AccountLocalData(defaults: defaults, credentials: credentials)
        self.localData = localData
        recentSearches = RecentSearchStore(defaults: defaults)
        seerr = SeerrSessionStore(client: seerrClient ?? SeerrClient(), defaults: defaults, localData: localData)
        isAccountDraft = accountDraft
        let deviceId: String
        if let stored = credentials.string(for: KeychainKey.deviceId) {
            deviceId = stored
        } else {
            deviceId = UUID().uuidString
            try? credentials.set(deviceId, for: KeychainKey.deviceId)
        }
        client = JellyfinClient(deviceId: deviceId, sessionConfiguration: sessionConfiguration)
        client.onSessionExpired = { [weak self] identity in self?.sessionExpired(identity) }
        if !accountDraft {
            retryCredentialCleanup()
            restore()
            if activeAccount == nil { synchronizeAccountContext() }
        }
    }

    private func synchronizeAccountContext() {
        guard !isAccountDraft else { return }
        recentSearches.configure(accountID: activeAccount?.id)
        TopShelfStore.activate(accountID: activeAccount?.id)
        seerr.select(activeAccount)
    }

    func retryCredentialCleanup() {
        do {
            try localData.retryPendingRemovals()
            cleanupErrorMessage = nil
        } catch { reportCleanupFailure() }
    }

    private func reportCleanupFailure() {
        cleanupErrorMessage = "The account's local access has been removed, but some saved credentials could not be deleted. Retry cleanup before adding that account again."
    }

    private func restore() {
        migrateLegacySessionIfNeeded()
        accounts = loadAccounts()

        // Resume the last account rather than asking every launch. A single
        // profile shouldn't have to be picked before every session; the
        // picker is reachable from Settings whenever it is wanted.
        if let id = defaults.string(forKey: DefaultsKey.activeAccountId),
           let account = accounts.first(where: { $0.id == id }) {
            if !activate(account) { beginReauthentication(account) }
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
    /// has gone or has been rejected. Restore never probes the server, so
    /// offline startup preserves usable remembered sessions.
    @discardableResult
    private func activate(_ account: StoredAccount) -> Bool {
        guard !expiredAccountIDs.contains(account.id),
              !localData.pendingAccountIDs.contains(account.id),
              let token = credentials.string(for: account.keychainAccount) else { return false }
        client.configure(serverURL: account.serverURL)
        client.activateSession(token: token, userId: account.userId)
        activeAccount = account
        reauthenticationAccount = nil
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
        connectionGeneration += 1
        // The shelf still shows the outgoing user's viewing until Home
        // refreshes; on a TV anyone in the room can read it (HEL-37).
        TopShelfStore.clear()
        client.clearSession()
        guard !activate(account) else { return }
        // The account outlived its token. Send them to sign-in for *that*
        // server rather than leaving a dead entry in the picker.
        beginReauthentication(account)
    }

    func showAccountPicker() {
        connectionGeneration += 1
        client.clearSession()
        activeAccount = nil
        reauthenticationAccount = nil
        userName = nil
        phase = .choosingAccount
    }

    private var expiredAccountIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: DefaultsKey.expiredAccounts) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: DefaultsKey.expiredAccounts) }
    }

    private func sessionExpired(_ identity: JellyfinClient.SessionIdentity) {
        guard !isAccountDraft, let account = activeAccount,
              account.serverURL == identity.serverURL, account.userId == identity.userId else { return }
        // Persist rejection before attempting Keychain deletion. A temporary
        // Keychain failure must not reactivate this token on the next launch.
        expiredAccountIDs.insert(account.id)
        try? credentials.delete(account.keychainAccount)
        TopShelfStore.clear()
        isAddingAccount = false
        beginReauthentication(account)
    }

    private func beginReauthentication(_ account: StoredAccount) {
        connectionGeneration += 1
        client.clearSession()
        client.configure(serverURL: account.serverURL)
        activeAccount = nil
        reauthenticationAccount = account
        serverName = account.serverName
        userName = account.userName
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)
        defaults.set(account.serverURL.absoluteString, forKey: DefaultsKey.serverURL)
        defaults.set(account.serverName, forKey: DefaultsKey.serverName)
        phase = .needsSignIn
    }

    /// Starts adding a server+user alongside the ones already remembered.
    func addAccount() {
        isAddingAccount = true
    }

    /// Reuse only the active server's address and name, never its user or
    /// credentials. With no active account, setup still asks for a server.
    func makeAccountDraft() -> SessionStore {
        let draft = SessionStore(accountDraft: true, defaults: defaults, sessionConfiguration: sessionConfiguration, credentials: credentials)
        if let account = activeAccount {
            draft.client.configure(serverURL: account.serverURL)
            draft.serverName = account.serverName
            draft.phase = .needsSignIn
        }
        return draft
    }

    /// Setup uses a separate client and never persists a server or token
    /// until the parent accepts a completed sign-in. Cancel leaves the
    /// active account, its requests, and its Seerr connection untouched.
    func cancelAccountDraft() {
        guard isAccountDraft else { return }
        draftCancelled = true
        connectionGeneration += 1
        pendingAuthentication = nil
        client.clearSession()
    }

    func finishAddingAccount(from draft: SessionStore) throws {
        guard draft.isAccountDraft, !draft.draftCancelled,
              let account = draft.activeAccount,
              let result = draft.pendingAuthentication else { throw CancellationError() }
        try persistSignIn(result, account: account)
        switchTo(account)
        isAddingAccount = false
    }

    private func checkConnection(_ generation: Int) throws {
        try Task.checkCancellation()
        guard !draftCancelled, generation == connectionGeneration else { throw CancellationError() }
    }

    /// Forgets an account from the picker, token and all.
    func remove(_ account: StoredAccount) throws {
        localData.beginRemoval(accountID: account.id)
        expiredAccountIDs.remove(account.id)
        let removedActiveAccount = activeAccount?.id == account.id || reauthenticationAccount?.id == account.id
        save(accounts: accounts.filter { $0.id != account.id })
        if !accounts.contains(where: { $0.serverURL == account.serverURL }) {
            defaults.removeObject(forKey: AccountLocalData.seerrServerKey(account))
        }
        if removedActiveAccount {
            connectionGeneration += 1
            TopShelfStore.clear()
            client.clearSession()
            activeAccount = nil
            reauthenticationAccount = nil
            serverName = nil
            userName = nil
            defaults.removeObject(forKey: DefaultsKey.activeAccountId)
            defaults.removeObject(forKey: DefaultsKey.serverURL)
            defaults.removeObject(forKey: DefaultsKey.serverName)
        }
        if accounts.isEmpty {
            TopShelfStore.clear()
            client.clearSession()
            phase = .needsServer
        } else if removedActiveAccount {
            phase = .choosingAccount
        }
        do {
            try localData.finishRemoval(accountID: account.id)
            if localData.pendingAccountIDs.isEmpty { cleanupErrorMessage = nil }
        } catch {
            reportCleanupFailure()
            throw error
        }
    }

    /// Libraries last seen for the active account, so the tab bar can draw
    /// at launch instead of popping in when the fetch lands (HEL-61).
    ///
    /// Keyed by account on purpose: servers have different libraries, and
    /// showing the previous account's tabs for a moment after a switch would
    /// be worse than showing none.
    func cachedLibraries() -> [LibraryTab] {
        guard let key = libraryCacheKey, let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([LibraryTab].self, from: data)) ?? []
    }

    func cacheLibraries(_ libraries: [LibraryTab]) {
        guard let key = libraryCacheKey else { return }
        defaults.set(try? JSONEncoder().encode(libraries), forKey: key)
    }

    private var libraryCacheKey: String? {
        activeAccount.map { "libraries.\($0.id)" }
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
              let token = credentials.string(for: KeychainKey.legacyAccessToken) else { return }

        let account = StoredAccount(
            serverURL: url,
            serverName: defaults.string(forKey: DefaultsKey.serverName),
            userId: userId,
            userName: defaults.string(forKey: DefaultsKey.legacyUserName)
        )
        do {
            try credentials.set(token, for: account.keychainAccount)
            guard credentials.string(for: account.keychainAccount) == token else {
                throw KeychainStore.StoreError.verificationFailed
            }
        } catch {
            // The old slot remains the source of truth. Never turn a failed
            // migration into a silent sign-out.
            return
        }
        save(accounts: [account])
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)

        try? credentials.delete(KeychainKey.legacyAccessToken)
        defaults.removeObject(forKey: DefaultsKey.legacyUserId)
        defaults.removeObject(forKey: DefaultsKey.legacyUserName)
    }

    // MARK: - Connect

    func connect(to input: String) async throws {
        connectionGeneration += 1
        let generation = connectionGeneration
        try checkConnection(generation)
        var lastError: Error = JellyfinError.invalidServerURL
        for url in Self.candidateURLs(for: input) {
            do {
                let info = try await JellyfinClient.fetchPublicInfo(at: url)
                try checkConnection(generation)
                client.configure(serverURL: url)
                serverName = info.serverName
                if !isAccountDraft {
                    defaults.set(url.absoluteString, forKey: DefaultsKey.serverURL)
                    defaults.set(info.serverName, forKey: DefaultsKey.serverName)
                }
                phase = .needsSignIn
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try checkConnection(generation)
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
        let generation = connectionGeneration
        try checkConnection(generation)
        let result = try await client.authenticateByName(username: username, password: password)
        try checkConnection(generation)
        try completeSignIn(with: result)
    }

    #if DEBUG
    /// Makes the UI regression suite runnable on a clean simulator. The
    /// public Jellyfin demo is the zero-configuration default. A richer
    /// private fixture server can be supplied through test-process launch
    /// environment without putting its credentials in the project or
    /// command-line arguments; this hook cannot ship in Release builds.
    func bootstrapPublicDemoForRegressionIfRequested() async {
        guard UserDefaults.standard.bool(forKey: "debug.playerRegression"),
              UserDefaults.standard.bool(forKey: "debug.regressionBootstrapPublicDemo"),
              phase != .signedIn else { return }
        let environment = ProcessInfo.processInfo.environment
        let address = environment["LAGOON_REGRESSION_SERVER"]
            ?? "https://demo.jellyfin.org/stable"
        let username = environment["LAGOON_REGRESSION_USER"] ?? "demo"
        let password = environment["LAGOON_REGRESSION_PASS"] ?? ""
        do {
            try await connect(to: address)
            let result = try await client.authenticateByName(username: username, password: password)
            guard let url = client.serverURL else { return }
            if UserDefaults.standard.bool(forKey: "debug.accountPrivacyRegression"), url.host == "127.0.0.1" {
                // Synthetic UI fixture only: exercise normal credential and
                // account persistence, then let tests drive the real picker.
                try completeSignIn(with: result)
                if let term = environment["LAGOON_REGRESSION_SEARCH"] { recentSearches.record(term) }
                return
            }
            // UI tests run in an ephemeral simulator session. Activating the
            // documented demo token directly avoids making the regression
            // harness depend on keychain entitlements or persisted accounts.
            let account = StoredAccount(
                serverURL: url,
                serverName: serverName,
                userId: result.user.id,
                userName: result.user.name
            )
            client.activateSession(token: result.accessToken, userId: result.user.id)
            activeAccount = account
            userName = result.user.name
            phase = .signedIn
        } catch {
            print("RegressionBootstrap failed: \(error.localizedDescription)")
        }
    }
    #endif

    func quickConnectAvailable() async -> Bool {
        (try? await client.quickConnectEnabled()) ?? false
    }

    func startQuickConnect() async throws -> QuickConnectResult {
        try await client.initiateQuickConnect()
    }

    /// One poll step; returns true once the user has approved the code
    /// on another device and the session is active.
    func pollQuickConnect(secret: String) async throws -> Bool {
        let generation = connectionGeneration
        try checkConnection(generation)
        let state = try await client.quickConnectState(secret: secret)
        try checkConnection(generation)
        guard state.authenticated else { return false }
        let result = try await client.authenticateWithQuickConnect(secret: secret)
        try checkConnection(generation)
        try completeSignIn(with: result)
        return true
    }

    private func completeSignIn(with result: AuthenticationResult) throws {
        guard let url = client.serverURL else { return }
        let account = StoredAccount(
            serverURL: url,
            serverName: serverName,
            userId: result.user.id,
            userName: result.user.name
        )
        if isAccountDraft {
            pendingAuthentication = result
        } else {
            try persistSignIn(result, account: account)
        }

        // Sign-in already carries the account's policy; taking it here saves
        // the extra Users/Me round trip a restored token has to make.
        client.activateSession(
            token: result.accessToken,
            userId: result.user.id,
            policy: result.user.policy
        )
        activeAccount = account
        reauthenticationAccount = nil
        userName = result.user.name
        phase = .signedIn
    }

    private func persistSignIn(_ result: AuthenticationResult, account: StoredAccount) throws {
        // Re-adding must not resurrect cookies left by a failed local forget.
        try localData.finishRemoval(accountID: account.id)
        try credentials.set(result.accessToken, for: account.keychainAccount)
        guard credentials.string(for: account.keychainAccount) == result.accessToken else {
            throw KeychainStore.StoreError.verificationFailed
        }
        expiredAccountIDs.remove(account.id)
        save(accounts: loadAccounts().filter { $0.id != account.id } + [account])
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)
        defaults.set(account.serverURL.absoluteString, forKey: DefaultsKey.serverURL)
        defaults.set(account.serverName, forKey: DefaultsKey.serverName)
    }

    // MARK: - Sign-out

    /// Signs out and *forgets* the active account — the token is revoked
    /// server-side, so keeping the entry would only offer a dead session.
    /// Any other remembered account survives, and the picker takes over.
    func signOut() async {
        connectionGeneration += 1
        let account = activeAccount ?? reauthenticationAccount
        let remote = client.sessionSnapshot()
        let linkedRemote = seerr.client.sessionSnapshot()
        // Privacy cleanup precedes network suspension. Even offline logout
        // immediately drops local access; late responses affect only copies.
        if let account { try? remove(account) }
        client.clearSession()
        activeAccount = nil
        reauthenticationAccount = nil
        userName = nil
        defaults.removeObject(forKey: DefaultsKey.activeAccountId)
        phase = accounts.isEmpty ? .needsSignIn : .choosingAccount
        async let jellyfinLogout: Void? = try? remote.logout()
        async let seerrLogout: Void? = linkedRemote.sessionCookie == nil ? nil : try? linkedRemote.logout()
        _ = await (jellyfinLogout, seerrLogout)
    }

    func forgetServer() async {
        connectionGeneration += 1
        reauthenticationAccount = nil
        if isAccountDraft {
            client.clearSession()
            activeAccount = nil
            pendingAuthentication = nil
            serverName = nil
            userName = nil
            phase = .needsServer
            return
        }
        // Invalidate immediately, and do not touch a later account after
        // waiting for revocation of this one.
        let remote = client.sessionSnapshot()
        let linkedRemote = seerr.client.sessionSnapshot()
        if let account = activeAccount { try? remove(account) }
        client.clearSession()
        activeAccount = nil
        defaults.removeObject(forKey: DefaultsKey.activeAccountId)
        defaults.removeObject(forKey: DefaultsKey.serverURL)
        defaults.removeObject(forKey: DefaultsKey.serverName)
        serverName = nil
        phase = .needsServer
        async let jellyfinLogout: Void? = try? remote.logout()
        async let seerrLogout: Void? = linkedRemote.sessionCookie == nil ? nil : try? linkedRemote.logout()
        _ = await (jellyfinLogout, seerrLogout)
    }
}

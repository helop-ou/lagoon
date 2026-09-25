import Foundation
import Observation

/// Owns which server, user and token are active. Server and user live in
/// UserDefaults; the token and device id live in the keychain.
@Observable
final class SessionStore {
    enum Phase {
        case needsServer
        case needsSignIn
        /// Several accounts remembered, none active: the profile picker.
        case choosingAccount
        case signedIn
    }

    private(set) var phase: Phase = .needsServer
    private(set) var serverName: String?
    private(set) var userName: String?
    /// In the order they were added.
    private(set) var accounts: [StoredAccount] = []
    private(set) var activeAccount: StoredAccount? {
        didSet { synchronizeAccountContext() }
    }
    /// Retained identity for reauthentication; it has no active credential.
    private(set) var reauthenticationAccount: StoredAccount?
    var isAddingAccount = false
    let client: JellyfinClient
    let seerr: SeerrSessionStore
    /// Owned here because a SyncPlay group belongs to the account that joined it.
    let syncPlay = SyncPlayStore()
    let recentSearches: RecentSearchStore
    var cleanupErrorMessage: String?

    private let defaults: UserDefaults
    private let isAccountDraft: Bool
    private let sessionConfiguration: URLSessionConfiguration
    private let localData: AccountLocalData
    private let credentials: any AccountCredentialStorage
    private let publicInfo: @Sendable (URL) async throws -> PublicSystemInfo
    private var draftCancelled = false
    private var pendingAuthentication: AuthenticationResult?
    private var connectionGeneration = 0

    #if DEBUG
    private static var didResetStateForRegression = false
    #endif

    private enum DefaultsKey {
        /// The server being connected to now. The accounts list gains an
        /// entry only once credentials work.
        static let serverURL = "server.url"
        static let serverName = "server.name"
        static let accounts = "accounts"
        static let activeAccountId = "session.activeAccountId"
        static let expiredAccounts = "session.expiredAccountIds"
        /// The pre-migration single-slot layout. Read once by the migration.
        static let legacyUserId = "session.userId"
        static let legacyUserName = "session.userName"
    }

    private enum KeychainKey {
        /// The pre-migration single-slot layout. Read once by the migration.
        static let legacyAccessToken = "accessToken"
        static let deviceId = "deviceId"
    }

    init(accountDraft: Bool = false, defaults: UserDefaults = .standard,
         sessionConfiguration: URLSessionConfiguration = .default,
         credentials: any AccountCredentialStorage = SystemAccountCredentials(),
         seerrClient: SeerrClient? = nil,
         publicInfo: @escaping @Sendable (URL) async throws -> PublicSystemInfo = JellyfinClient.fetchPublicInfo) {
        self.defaults = defaults
        self.sessionConfiguration = sessionConfiguration
        self.credentials = credentials
        self.publicInfo = publicInfo
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
            #if DEBUG
            // Regression lane: clear what an earlier run left before restore()
            // re-activates it. Once per process, so the account-draft store skips it.
            if RegressionStateReset.isRequested(), !Self.didResetStateForRegression {
                Self.didResetStateForRegression = true
                let removed = RegressionStateReset.run(defaults: defaults, credentials: credentials)
                TopShelfStore.clear()
                print("RegressionStateReset: removed \(removed.defaultsKeys.count) defaults keys and \(removed.credentialNames.count) credentials")
            }
            #endif
            retryCredentialCleanup()
            restore()
            // Sweep state left by the retired direct OpenSubtitles integration.
            RetiredSubtitleProviderCleanup.run(
                defaults: defaults,
                credentials: credentials,
                cachesDirectory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            )
            if activeAccount == nil { synchronizeAccountContext() }
        }
    }

    private func synchronizeAccountContext() {
        guard !isAccountDraft else { return }
        recentSearches.configure(accountID: activeAccount?.id)
        // Include the re-authenticating account so its sign-in screen keeps its theme.
        ThemeStore.shared.configure(accountID: (activeAccount ?? reauthenticationAccount)?.id, owner: ObjectIdentifier(self))
        TopShelfStore.activate(accountID: activeAccount?.id)
        seerr.select(activeAccount)
        // Leaves the previous account's group, socket and clock.
        syncPlay.configure(client: client, accountID: activeAccount?.id)
        #if os(iOS)
        DownloadStore.shared.activate(accountID: activeAccount?.id, owner: ObjectIdentifier(self))
        if activeAccount != nil {
            Task { await DownloadStore.shared.refreshPermission(client: client) }
        }
        #endif
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

        // Resume the last account; the picker is in Settings.
        if let id = defaults.string(forKey: DefaultsKey.activeAccountId),
           let account = accounts.first(where: { $0.id == id }) {
            if !activate(account) { beginReauthentication(account) }
            return
        }

        if !accounts.isEmpty {
            phase = .choosingAccount
            return
        }

        // No accounts: resume an interrupted sign-in.
        guard let urlString = defaults.string(forKey: DefaultsKey.serverURL),
              let url = URL(string: urlString) else {
            phase = .needsServer
            return
        }
        client.configure(serverURL: url)
        serverName = defaults.string(forKey: DefaultsKey.serverName)
        phase = .needsSignIn
    }

    // MARK: - Accounts

    /// Fails only when the token is gone or rejected. Never probes the
    /// server, so offline startup keeps remembered sessions usable.
    @discardableResult
    private func activate(_ account: StoredAccount) -> Bool {
        guard !expiredAccountIDs.contains(account.id),
              !localData.pendingAccountIDs.contains(account.id),
              let token = credentials.string(for: account.keychainAccount) else { return false }
        var account = account
        account.lastUsedAt = Date.now.timeIntervalSince1970
        save(accounts: accounts.map { $0.id == account.id ? account : $0 })
        client.configure(serverURL: account.serverURL)
        client.activateSession(token: token, userId: account.userId)
        activeAccount = account
        reauthenticationAccount = nil
        serverName = account.serverName
        userName = account.userName
        defaults.set(account.id, forKey: DefaultsKey.activeAccountId)
        phase = .signedIn
        refreshProfile(of: account)
        return true
    }

    /// Catches up a changed name or picture after activation. An unreachable
    /// server keeps the stored record; a switch or sign-out mid-read discards it.
    private func refreshProfile(of account: StoredAccount) {
        let generation = connectionGeneration
        Task { [weak self] in
            guard let self, let user = try? await client.currentUser() else { return }
            guard connectionGeneration == generation,
                  phase == .signedIn,
                  activeAccount?.id == account.id,
                  user.id == account.userId else { return }
            let name = user.name ?? account.userName
            guard user.primaryImageTag != account.primaryImageTag || name != account.userName else { return }
            let updated = StoredAccount(
                serverURL: account.serverURL,
                serverName: account.serverName,
                userId: account.userId,
                userName: name,
                primaryImageTag: user.primaryImageTag
            )
            save(accounts: accounts.map { $0.id == updated.id ? updated : $0 })
            activeAccount = updated
            userName = updated.userName
        }
    }

    /// Every Jellyfin call is user-scoped, so the rest follows on its own.
    func switchTo(_ account: StoredAccount) {
        connectionGeneration += 1
        // Otherwise the shelf shows the outgoing user's viewing until Home refreshes.
        TopShelfStore.clear()
        client.clearSession()
        guard !activate(account) else { return }
        // Token gone: sign in again to that server.
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
        // Persist rejection before Keychain deletion, so a Keychain failure
        // cannot reactivate this token next launch.
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

    func addAccount() {
        isAddingAccount = true
    }

    /// Reuses the active server's address and name, never its user or credentials.
    func makeAccountDraft() -> SessionStore {
        let draft = SessionStore(accountDraft: true, defaults: defaults, sessionConfiguration: sessionConfiguration, credentials: credentials, publicInfo: publicInfo)
        if let account = activeAccount {
            draft.client.configure(serverURL: account.serverURL)
            draft.serverName = account.serverName
            draft.phase = .needsSignIn
        }
        return draft
    }

    /// Setup uses a separate client and persists nothing until the parent
    /// accepts a sign-in, so cancel leaves the active account untouched.
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

    /// Lets the tab bar draw at launch. Keyed by account so a switch never
    /// flashes the previous account's libraries.
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

    /// One-time move off the single-slot layout; without it an upgrade signs everyone out.
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
            // Keep the old slot; a failed migration must not sign out.
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
        let candidates = Self.candidateURLs(for: input)
        guard !candidates.isEmpty else { throw ServerAddress.Failure.invalid }
        var lastError: Error = JellyfinError.invalidServerURL
        for url in candidates {
            do {
                let info = try await publicInfo(url)
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
            } catch LocalNetworkAccess.Failure.denied {
                try checkConnection(generation)
                throw LocalNetworkAccess.Failure.denied
            } catch {
                try checkConnection(generation)
                lastError = error
            }
        }
        throw lastError
    }

    /// Schemeless input tries https and http, plus port 8096 when none is
    /// given. LAN-looking hosts try http first so https can't stall them.
    nonisolated static func candidateURLs(for input: String) -> [URL] {
        ServerAddress.candidateURLs(for: input, service: .jellyfin)
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
    /// Lets the UI regression suite run on a clean simulator, against the
    /// public demo or a fixture server from the launch environment. Not in Release.
    func bootstrapPublicDemoForRegressionIfRequested() async {
        // Not gated on `phase`: the lane must replace whatever account
        // restore() activated. Nothing here persists.
        guard UserDefaults.standard.bool(forKey: "debug.playerRegression"),
              UserDefaults.standard.bool(forKey: "debug.regressionBootstrapPublicDemo") else { return }
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
                // Fixture only: persist normally so tests drive the real picker.
                try completeSignIn(with: result)
                if let term = environment["LAGOON_REGRESSION_SEARCH"] { recentSearches.record(term) }
                return
            }
            // Activate directly so the harness needs no keychain or stored accounts.
            let account = StoredAccount(
                serverURL: url,
                serverName: serverName,
                userId: result.user.id,
                userName: result.user.name,
                primaryImageTag: result.user.primaryImageTag
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

    /// One poll step; true once the code is approved and the session is active.
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
            userName: result.user.name,
            primaryImageTag: result.user.primaryImageTag
        )
        if isAccountDraft {
            pendingAuthentication = result
        } else {
            try persistSignIn(result, account: account)
        }

        // Sign-in carries the policy, saving a Users/Me round trip.
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

    /// Forgets the active account, since its token is revoked. Other
    /// accounts survive and the picker takes over.
    func signOut() async {
        connectionGeneration += 1
        let account = activeAccount ?? reauthenticationAccount
        let remote = client.sessionSnapshot()
        let linkedRemote = seerr.client.sessionSnapshot()
        // Clean up locally before suspending the network, so offline logout
        // drops access at once.
        if let account { try? remove(account) }
        client.clearSession()
        activeAccount = nil
        reauthenticationAccount = nil
        userName = nil
        defaults.removeObject(forKey: DefaultsKey.activeAccountId)
        // `remove` cleared the stored server, so there is nothing to sign in to.
        phase = accounts.isEmpty ? .needsServer : .choosingAccount
        async let jellyfinLogout: Void? = try? remote.logout()
        async let seerrLogout: Void? = linkedRemote.sessionCookie == nil ? nil : try? linkedRemote.logout()
        _ = await (jellyfinLogout, seerrLogout)
    }

    func forgetServer() async {
        connectionGeneration += 1
        // A re-authenticating account is never the active one; keep it past
        // the reset or it stays in the picker with no way to remove it.
        let reauthenticating = reauthenticationAccount
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
        // Invalidate now; after revocation, leave any later account alone.
        let remote = client.sessionSnapshot()
        let linkedRemote = seerr.client.sessionSnapshot()
        if let account = activeAccount ?? reauthenticating { try? remove(account) }
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

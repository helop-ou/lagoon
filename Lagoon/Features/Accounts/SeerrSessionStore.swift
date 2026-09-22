import Foundation
import Observation

/// Follows the active Jellyfin account. The Seerr address is shared per
/// Jellyfin server; the session cookie is stored per account.
@Observable
final class SeerrSessionStore {
    private(set) var configuredURL: URL?
    private(set) var status: SeerrServerStatus?
    private(set) var publicSettings: SeerrPublicSettings?
    private(set) var user: SeerrUser?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var localNetworkAccessDenied = false

    let client: SeerrClient

    private let defaults: UserDefaults
    private let localData: AccountLocalData
    private var activeAccount: StoredAccount?
    private var activationToken = UUID()
    private var activationTask: Task<Void, Never>?
    /// One attempt per activation, so a server with Quick Connect off is not re-asked.
    private var hasAttemptedJellyfinSignIn = false

    init(client: SeerrClient = SeerrClient(), defaults: UserDefaults = .standard,
         localData: AccountLocalData? = nil) {
        self.client = client
        self.defaults = defaults
        self.localData = localData ?? AccountLocalData(defaults: defaults, credentials: SystemAccountCredentials())
    }

    var isConfigured: Bool { configuredURL != nil }
    var isConnected: Bool { user != nil }
    var displayName: String {
        if let user { return user.name }
        if isConfigured { return "Sign In Required" }
        return "Not Configured"
    }

    /// Only ever suggests this account's own configured Seerr server.
    func suggestedServerAddress(for account: StoredAccount?) -> String {
        if let configuredURL { return configuredURL.absoluteString }
        #if DEBUG
        if let paired = Self.developmentPairing(for: account) { return paired }
        #endif
        return ""
    }

    #if DEBUG
    /// Regression lane: a fixture Seerr address from the launch environment,
    /// like `LAGOON_REGRESSION_*`. Never in a shipping build.
    private static func developmentPairing(for account: StoredAccount?) -> String? {
        let environment = ProcessInfo.processInfo.environment
        guard let host = environment["LAGOON_SEERR_PAIRED_HOST"]?.lowercased(),
              let address = environment["LAGOON_SEERR_PAIRED_URL"],
              !host.isEmpty, !address.isEmpty,
              account?.serverURL.host()?.lowercased() == host else { return nil }
        return address
    }
    #endif

    func activate(for account: StoredAccount?) async {
        select(account)
        await activationTask?.value
    }

    /// Called synchronously before the next account is observable, so pending
    /// authentication cannot reinstall an outgoing cookie.
    func select(_ account: StoredAccount?) {
        activationTask?.cancel()
        let token = UUID()
        activationToken = token
        activeAccount = account
        configuredURL = nil
        status = nil
        publicSettings = nil
        user = nil
        isLoading = false
        errorMessage = nil
        hasAttemptedJellyfinSignIn = false
        localNetworkAccessDenied = false
        client.clear()

        guard let account,
              !localData.pendingAccountIDs.contains(account.id),
              let urlString = defaults.string(forKey: serverDefaultsKey(for: account)),
              let url = URL(string: urlString) else { return }
        activationTask = Task { await restore(url: url, account: account, activationToken: token) }
    }

    func connect(to input: String) async throws {
        guard let account = activeAccount else { throw SeerrError.unauthenticated }
        activationTask?.cancel()
        activationToken = UUID()
        let token = activationToken
        isLoading = true
        errorMessage = nil
        localNetworkAccessDenied = false
        defer {
            if activationToken == token { isLoading = false }
        }

        let candidates = SeerrClient.candidateURLs(for: input)
        guard !candidates.isEmpty else {
            errorMessage = ServerAddress.Failure.invalid.localizedDescription
            throw ServerAddress.Failure.invalid
        }
        var lastError: Error = SeerrError.invalidServerURL
        for candidate in candidates {
            guard activationToken == token, activeAccount?.id == account.id else { throw CancellationError() }
            client.clear()
            client.configure(serverURL: candidate)
            do {
                async let serverStatus = client.status()
                async let settings = client.publicSettings()
                let (resolvedStatus, resolvedSettings) = try await (serverStatus, settings)
                guard activationToken == token, activeAccount?.id == account.id else {
                    throw CancellationError()
                }
                guard resolvedSettings.initialized else {
                    throw SeerrError.server(409, "Finish setting up this Seerr server before connecting Lagoon.")
                }
                // Lagoon accounts are Jellyfin identities; refuse a Plex Seerr.
                if let mediaServerType = resolvedSettings.mediaServerType, mediaServerType != 2 {
                    throw SeerrError.server(409, "This Seerr server is not configured for Jellyfin.")
                }

                let normalizedURL = client.serverURL ?? candidate
                configuredURL = normalizedURL
                status = resolvedStatus
                publicSettings = resolvedSettings
                defaults.set(normalizedURL.absoluteString, forKey: serverDefaultsKey(for: account))
                await restoreSavedSession(for: account)
                return
            } catch is CancellationError {
                if activationToken == token { client.clear() }
                throw CancellationError()
            } catch LocalNetworkAccess.Failure.denied {
                guard activationToken == token, activeAccount?.id == account.id else { throw CancellationError() }
                client.clear()
                localNetworkAccessDenied = true
                errorMessage = LocalNetworkAccess.Failure.denied.localizedDescription
                throw LocalNetworkAccess.Failure.denied
            } catch {
                guard activationToken == token, activeAccount?.id == account.id else { throw CancellationError() }
                lastError = error
            }
        }
        client.clear()
        errorMessage = lastError.localizedDescription
        throw lastError
    }

    func startQuickConnect() async throws -> SeerrQuickConnect {
        guard isConfigured else { throw SeerrError.invalidServerURL }
        errorMessage = nil
        return try await client.initiateQuickConnect()
    }

    func pollQuickConnect(secret: String) async throws -> Bool {
        let token = activationToken
        let accountID = activeAccount?.id
        let state = try await client.quickConnectState(secret: secret)
        guard activationToken == token, activeAccount?.id == accountID else {
            throw CancellationError()
        }
        guard state.authenticated else { return false }
        let authenticatedUser = try await client.authenticateQuickConnect(secret: secret)
        guard activationToken == token, activeAccount?.id == accountID else {
            throw CancellationError()
        }
        try finishAuthentication(user: authenticatedUser)
        return true
    }

    /// Signs in to Seerr with the Jellyfin session. Lagoon keeps no password,
    /// so Jellyseerr requests a Quick Connect code and Lagoon approves it.
    func signInUsingJellyfin(_ jellyfin: JellyfinClient) async throws {
        guard isConfigured else { throw SeerrError.invalidServerURL }
        guard jellyfin.serverURL == activeAccount?.serverURL, jellyfin.userId == activeAccount?.userId else {
            throw SeerrError.unauthenticated
        }
        let jellyfin = jellyfin.sessionSnapshot()
        let token = activationToken
        let accountID = activeAccount?.id
        errorMessage = nil

        // Quick Connect may be off; only the manual paths remain.
        guard (try? await jellyfin.quickConnectEnabled()) == true else {
            throw SeerrError.quickConnectUnavailable
        }
        guard activationToken == token, activeAccount?.id == accountID else {
            throw CancellationError()
        }

        let handshake = try await client.initiateQuickConnect()
        guard activationToken == token, activeAccount?.id == accountID else { throw CancellationError() }
        _ = try await jellyfin.authorizeQuickConnect(code: handshake.code)

        // Jellyseerr may not see the approval on the first check.
        for delay in Self.quickConnectConfirmationDelays {
            try await Task.sleep(for: delay)
            guard activationToken == token, activeAccount?.id == accountID else {
                throw CancellationError()
            }
            if try await pollQuickConnect(secret: handshake.secret) { return }
        }
        throw SeerrError.unauthenticated
    }

    /// The automatic path; silent when there is nothing to do.
    func signInUsingJellyfinIfNeeded(_ jellyfin: JellyfinClient) async {
        guard isConfigured, !isConnected, !isLoading, !hasAttemptedJellyfinSignIn else { return }
        hasAttemptedJellyfinSignIn = true
        let token = activationToken
        do {
            try await signInUsingJellyfin(jellyfin)
        } catch is CancellationError {
        } catch {
            guard activationToken == token else { return }
            // A fallback, not a failure: note it without an error screen.
            errorMessage = error.localizedDescription
        }
    }

    nonisolated static let quickConnectConfirmationDelays: [Duration] = [
        .zero,
        .milliseconds(400),
        .seconds(1),
        .seconds(2),
    ]

    func signIn(username: String, password: String) async throws {
        let token = activationToken
        let accountID = activeAccount?.id
        errorMessage = nil
        let authenticatedUser = try await client.authenticateJellyfin(
            username: username,
            password: password
        )
        guard activationToken == token, activeAccount?.id == accountID else {
            throw CancellationError()
        }
        try finishAuthentication(user: authenticatedUser)
    }

    func refreshUser() async {
        guard isConfigured, client.sessionCookie != nil else {
            user = nil
            return
        }
        let token = activationToken
        let accountID = activeAccount?.id
        do {
            let refreshedUser = try await client.currentUser()
            guard activationToken == token, activeAccount?.id == accountID else { return }
            user = refreshedUser
            try persistCurrentCookie()
            errorMessage = nil
        } catch is CancellationError {
        } catch SeerrError.unauthenticated {
            guard activationToken == token, activeAccount?.id == accountID else { return }
            clearSavedCookie()
            user = nil
        } catch {
            guard activationToken == token, activeAccount?.id == accountID else { return }
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        let remote = client.sessionSnapshot()
        activationTask?.cancel()
        activationToken = UUID()
        isLoading = false
        hasAttemptedJellyfinSignIn = true
        clearSavedCookie()
        client.setSessionCookie(nil)
        user = nil
        if remote.sessionCookie != nil { try? await remote.logout() }
    }

    func forgetServer() async {
        let remote = client.sessionSnapshot()
        activationTask?.cancel()
        activationToken = UUID()
        isLoading = false
        hasAttemptedJellyfinSignIn = true
        clearSavedCookie()
        if let activeAccount {
            defaults.removeObject(forKey: serverDefaultsKey(for: activeAccount))
        }
        client.clear()
        configuredURL = nil
        status = nil
        publicSettings = nil
        user = nil
        if remote.sessionCookie != nil { try? await remote.logout() }
    }

    private func restore(url: URL, account: StoredAccount, activationToken token: UUID) async {
        guard !Task.isCancelled, activationToken == token, activeAccount?.id == account.id else { return }
        isLoading = true
        defer {
            if activationToken == token { isLoading = false }
        }
        client.configure(serverURL: url)
        do {
            async let serverStatus = client.status()
            async let settings = client.publicSettings()
            let (resolvedStatus, resolvedSettings) = try await (serverStatus, settings)
            guard activationToken == token, activeAccount?.id == account.id else { return }
            configuredURL = client.serverURL ?? url
            status = resolvedStatus
            publicSettings = resolvedSettings
            await restoreSavedSession(for: account)
        } catch {
            guard activationToken == token else { return }
            configuredURL = client.serverURL ?? url
            localNetworkAccessDenied = error is LocalNetworkAccess.Failure
            errorMessage = error.localizedDescription
        }
    }

    private func restoreSavedSession(for account: StoredAccount) async {
        guard let configuredURL, !localData.pendingAccountIDs.contains(account.id) else { return }
        let token = activationToken
        let key = cookieKey(account: account, serverURL: configuredURL)
        guard !localData.pendingCookieKeys.contains(key) else {
            client.setSessionCookie(nil)
            user = nil
            errorMessage = "The saved Seerr credential could not be deleted. Sign in again to replace it."
            return
        }
        guard let cookie = localData.credentials.string(for: key) else {
            client.setSessionCookie(nil)
            user = nil
            return
        }
        client.setSessionCookie(cookie)
        do {
            let restoredUser = try await client.currentUser()
            guard activationToken == token, activeAccount?.id == account.id else { return }
            user = restoredUser
            try persistCurrentCookie()
        } catch is CancellationError {
        } catch SeerrError.unauthenticated {
            guard activationToken == token, activeAccount?.id == account.id else { return }
            do { try localData.removeSeerrCookie(key) }
            catch { errorMessage = "The expired Seerr credential could not be deleted. Sign in again to replace it." }
            client.setSessionCookie(nil)
            user = nil
        } catch {
            guard activationToken == token, activeAccount?.id == account.id else { return }
            // A transient network failure must not destroy a valid session.
            user = nil
            errorMessage = error.localizedDescription
        }
    }

    private func finishAuthentication(user: SeerrUser) throws {
        guard client.sessionCookie != nil else { throw SeerrError.invalidResponse }
        try persistCurrentCookie()
        self.user = user
        errorMessage = nil
    }

    private func persistCurrentCookie() throws {
        guard let activeAccount, let configuredURL, let cookie = client.sessionCookie else {
            throw SeerrError.invalidResponse
        }
        let key = cookieKey(account: activeAccount, serverURL: configuredURL)
        guard !localData.pendingAccountIDs.contains(activeAccount.id) else { throw CancellationError() }
        try localData.saveSeerrCookie(cookie, for: key)
    }

    private func clearSavedCookie() {
        guard let activeAccount, let configuredURL else { return }
        do {
            try localData.removeSeerrCookie(cookieKey(account: activeAccount, serverURL: configuredURL))
            errorMessage = nil
        } catch {
            errorMessage = "Local Seerr access has been removed, but the saved credential could not be deleted. Sign in again to replace it."
        }
        client.setSessionCookie(nil)
    }

    private func serverDefaultsKey(for account: StoredAccount) -> String {
        AccountLocalData.seerrServerKey(account)
    }

    private func cookieKey(account: StoredAccount, serverURL: URL) -> String {
        AccountLocalData.seerrCookieKey(account, serverURL: serverURL)
    }
}

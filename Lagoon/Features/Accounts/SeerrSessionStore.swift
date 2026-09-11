import Foundation
import Observation

/// Keeps Seerr identity aligned with Lagoon's active Jellyfin account. The
/// server address is shared by users of a Jellyfin server, while the opaque
/// Seerr session cookie is stored separately for every account.
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
    /// One attempt per activation. A server with Quick Connect off would
    /// otherwise be re-asked every time Discover appears.
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

    /// The user's known first-party pairing. It is only suggested for the
    /// matching Jellyfin host; other servers remain entirely user-configured.
    func suggestedServerAddress(for account: StoredAccount?) -> String {
        if let configuredURL { return configuredURL.absoluteString }
        if account?.serverURL.host()?.lowercased() == "fixture.example.eu" {
            return "https://seerr.example.eu"
        }
        return ""
    }

    func activate(for account: StoredAccount?) async {
        select(account)
        await activationTask?.value
    }

    /// SessionStore calls this synchronously before the next account can be
    /// observed. Pending authentication cannot reinstall an outgoing cookie.
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
                // Lagoon accounts are Jellyfin identities. Connecting them
                // to a Plex-only Seerr instance would silently create the
                // wrong authorization boundary.
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

    /// Signs in to Seerr using the Jellyfin session Lagoon already holds, so
    /// a viewer who is signed in to Jellyfin never sees a Seerr login at all.
    ///
    /// Jellyseerr's Jellyfin login takes a plaintext password, and Lagoon does
    /// not keep one — only an access token. Quick Connect closes that gap
    /// without a password: Jellyseerr asks Jellyfin for a code, and Lagoon,
    /// being an authenticated Jellyfin client, approves that code itself. It
    /// is the viewer's own account on both ends.
    func signInUsingJellyfin(_ jellyfin: JellyfinClient) async throws {
        guard isConfigured else { throw SeerrError.invalidServerURL }
        guard jellyfin.serverURL == activeAccount?.serverURL, jellyfin.userId == activeAccount?.userId else {
            throw SeerrError.unauthenticated
        }
        let jellyfin = jellyfin.sessionSnapshot()
        let token = activationToken
        let accountID = activeAccount?.id
        errorMessage = nil

        // Quick Connect is a server setting and may be off, in which case
        // there is nothing to fall back on but the manual paths.
        guard (try? await jellyfin.quickConnectEnabled()) == true else {
            throw SeerrError.quickConnectUnavailable
        }
        guard activationToken == token, activeAccount?.id == accountID else {
            throw CancellationError()
        }

        let handshake = try await client.initiateQuickConnect()
        guard activationToken == token, activeAccount?.id == accountID else { throw CancellationError() }
        _ = try await jellyfin.authorizeQuickConnect(code: handshake.code)

        // Jellyseerr verifies the code against Jellyfin on its own schedule,
        // so the approval is not always visible on the first check.
        for delay in Self.quickConnectConfirmationDelays {
            try await Task.sleep(for: delay)
            guard activationToken == token, activeAccount?.id == accountID else {
                throw CancellationError()
            }
            if try await pollQuickConnect(secret: handshake.secret) { return }
        }
        throw SeerrError.unauthenticated
    }

    /// The automatic path. Silent when there is nothing to do, and attempted
    /// only once per activation so a server without Quick Connect is not
    /// re-asked on every appearance.
    func signInUsingJellyfinIfNeeded(_ jellyfin: JellyfinClient) async {
        guard isConfigured, !isConnected, !isLoading, !hasAttemptedJellyfinSignIn else { return }
        hasAttemptedJellyfinSignIn = true
        let token = activationToken
        do {
            try await signInUsingJellyfin(jellyfin)
        } catch is CancellationError {
        } catch {
            guard activationToken == token else { return }
            // The manual paths remain, so this is a fallback rather than a
            // failure: say what happened without turning Discover into an
            // error screen.
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

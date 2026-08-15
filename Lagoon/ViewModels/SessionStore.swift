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
        case signedIn
    }

    private(set) var phase: Phase = .needsServer
    private(set) var serverName: String?
    private(set) var userName: String?
    let client: JellyfinClient

    private let defaults = UserDefaults.standard

    private enum DefaultsKey {
        static let serverURL = "server.url"
        static let serverName = "server.name"
        static let userId = "session.userId"
        static let userName = "session.userName"
    }

    private enum KeychainKey {
        static let accessToken = "accessToken"
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
        guard let urlString = defaults.string(forKey: DefaultsKey.serverURL),
              let url = URL(string: urlString) else {
            phase = .needsServer
            return
        }
        client.configure(serverURL: url)
        serverName = defaults.string(forKey: DefaultsKey.serverName)
        guard let userId = defaults.string(forKey: DefaultsKey.userId),
              let token = KeychainStore.string(for: KeychainKey.accessToken) else {
            phase = .needsSignIn
            return
        }
        userName = defaults.string(forKey: DefaultsKey.userName)
        client.activateSession(token: token, userId: userId)
        phase = .signedIn
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
        client.activateSession(token: result.accessToken, userId: result.user.id)
        KeychainStore.set(result.accessToken, for: KeychainKey.accessToken)
        defaults.set(result.user.id, forKey: DefaultsKey.userId)
        defaults.set(result.user.name, forKey: DefaultsKey.userName)
        userName = result.user.name
        phase = .signedIn
    }

    // MARK: - Sign-out

    func signOut() async {
        try? await client.logout()
        client.clearSession()
        KeychainStore.delete(KeychainKey.accessToken)
        defaults.removeObject(forKey: DefaultsKey.userId)
        defaults.removeObject(forKey: DefaultsKey.userName)
        userName = nil
        phase = .needsSignIn
    }

    func forgetServer() async {
        await signOut()
        defaults.removeObject(forKey: DefaultsKey.serverURL)
        defaults.removeObject(forKey: DefaultsKey.serverName)
        serverName = nil
        phase = .needsServer
    }
}

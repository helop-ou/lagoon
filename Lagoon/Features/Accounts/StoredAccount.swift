import Foundation

/// One remembered server+user pair, safe for UserDefaults. The token lives
/// in the keychain under `keychainAccount`.
nonisolated struct StoredAccount: Codable, Identifiable, Hashable {
    let serverURL: URL
    let serverName: String?
    let userId: String
    let userName: String?
    /// Refreshed from `Users/Me` on activation. Older records decode without it.
    var primaryImageTag: String? = nil

    /// Server and user id, never display names, so a rename cannot orphan
    /// the token or duplicate the account.
    var id: String { "\(serverURL.absoluteString)|\(userId)" }

    var keychainAccount: String { "token:\(id)" }

    var displayName: String { userName ?? "User" }
    var serverLabel: String { serverName ?? serverURL.host() ?? serverURL.absoluteString }

    /// Built from the account's own server, so it works for inactive accounts too.
    func avatarURL(maxWidth: Int) -> URL? {
        JellyfinClient.userImageURL(serverURL: serverURL, userId: userId, tag: primaryImageTag, maxWidth: maxWidth)
    }
}

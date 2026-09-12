import Foundation

/// One remembered server+user pair (HEL-38).
///
/// Everything here is safe for UserDefaults; the access token is the one
/// piece that isn't, and lives in the keychain under `keychainAccount`.
/// `KeychainStore` already keys by an arbitrary account string, so holding
/// several tokens at once needed no change there — only a key that includes
/// the server and user rather than the bare `"accessToken"` the single-slot
/// layout used.
nonisolated struct StoredAccount: Codable, Identifiable, Hashable {
    let serverURL: URL
    let serverName: String?
    let userId: String
    let userName: String?
    /// Jellyfin's tag for the user's profile picture, nil when there is
    /// none. Taken at sign-in and refreshed from `Users/Me` whenever the
    /// account is activated, so a picture set or changed on the web follows
    /// (HEL-168). Records written before the field decode without it.
    var primaryImageTag: String? = nil

    /// Identity is the server and the user id, never the display names:
    /// an admin renaming the server, or a user changing their display name,
    /// must not orphan the token or duplicate the account.
    var id: String { "\(serverURL.absoluteString)|\(userId)" }

    var keychainAccount: String { "token:\(id)" }

    /// What the picker shows under the avatar. The server only earns a line
    /// of its own when more than one is signed in — see `AccountPickerView`.
    var displayName: String { userName ?? "User" }
    var serverLabel: String { serverName ?? serverURL.host() ?? serverURL.absoluteString }

    /// The profile picture at the account's own server, so the picker can
    /// show every remembered account whichever one is active. nil without
    /// a picture; the views draw initials then.
    func avatarURL(maxWidth: Int) -> URL? {
        JellyfinClient.userImageURL(serverURL: serverURL, userId: userId, tag: primaryImageTag, maxWidth: maxWidth)
    }
}

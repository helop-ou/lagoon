import Foundation

/// Publishes a Continue Watching snapshot for the Top Shelf extension
/// (HEL-37).
///
/// The extension holds **no credentials and does no networking** — it draws
/// whatever the app last wrote here. That is deliberate: sharing a keychain
/// access group with an extension is a bigger trust boundary than this
/// feature needs. It works because Jellyfin's `Items/{id}/Images/...`
/// routes are unauthenticated; the trickplay route is the one image
/// endpoint that isn't, and it plays no part here.
enum TopShelfStore {
    /// Mirrored by `TopShelfItem` in `LagoonTopShelf/ContentProvider.swift`.
    /// An app extension cannot import the app's module, and a framework
    /// target for five fields would cost more than it saves, so both sides
    /// encode the same key names instead. **Change one, change the other.**
    nonisolated struct Item: Codable {
        let id: String
        let title: String
        let subtitle: String?
        let imageURLString: String?
        let progress: Double?
    }

    private static let appGroupID = "group.ee.helop.lagoon"
    private static let itemsKey = "topShelf.continueWatching"
    /// The shelf shows a handful at most; writing the whole rail is waste.
    private static let limit = 8

    /// No-ops when the App Group isn't provisioned, so the app behaves
    /// normally on a build without the entitlement.
    static func publish(_ items: [MediaItem], client: JellyfinClient) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let payload = items.prefix(limit).map { item in
            Item(
                id: item.id,
                title: item.railTitle,
                subtitle: item.railSubtitle,
                imageURLString: client.imageURL(for: item, kind: .thumb, maxWidth: 800)?.absoluteString,
                progress: item.playbackProgress
            )
        }
        defaults.set(try? JSONEncoder().encode(payload), forKey: itemsKey)
    }

    /// Signing out or switching account has to wipe this. The Top Shelf sits
    /// on the TV's home screen where anyone in the room can read it, so
    /// leaving the previous user's viewing there would be a small but real
    /// privacy leak — and HEL-38 made switching easy, which makes it
    /// reachable.
    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: itemsKey)
    }
}

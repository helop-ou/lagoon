import Foundation
import Observation

/// Turns the Top Shelf's `lagoon://` URLs into something the UI can act on
/// once there is a signed-in client to resolve them against.
@Observable
final class DeepLinkRouter {
    /// The item to start playing, cleared once the UI has acted on it.
    var pendingItemID: String?
    /// The item to open a detail page for. The Top Shelf carousel offers
    /// Play and More Info as two separate buttons, and they have to do two
    /// separate things (HEL-119).
    var pendingDetailItemID: String?

    /// URL contract shared with `LagoonTopShelf/ContentProvider.swift`:
    /// `lagoon://play/{itemId}` plays, `lagoon://item/{itemId}` opens the
    /// detail page. An unknown host is ignored rather than guessed at.
    func handle(_ url: URL) {
        guard url.scheme == "lagoon" else { return }
        let id = url.pathComponents.filter { $0 != "/" }.first
        guard let id, !id.isEmpty else { return }
        switch url.host() {
        case "play": pendingItemID = id
        case "item": pendingDetailItemID = id
        default: return
        }
    }
}

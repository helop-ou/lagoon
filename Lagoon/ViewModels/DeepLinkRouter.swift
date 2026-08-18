import Foundation
import Observation

/// Turns the Top Shelf's `lagoon://` URLs into something the UI can act on
/// (HEL-37).
///
/// Kept separate from `SessionStore` because a deep link can arrive before
/// there is a session at all — a cold launch straight from the TV's home
/// screen — and the request has to survive until sign-in finishes rather
/// than being dropped.
@Observable
final class DeepLinkRouter {
    /// The item the user picked, cleared once the UI has acted on it.
    var pendingItemID: String?

    /// URL contract shared with `LagoonTopShelf/ContentProvider.swift`:
    /// `lagoon://play/{itemId}`.
    func handle(_ url: URL) {
        guard url.scheme == "lagoon", url.host() == "play" else { return }
        let id = url.pathComponents.filter { $0 != "/" }.first
        guard let id, !id.isEmpty else { return }
        pendingItemID = id
    }
}

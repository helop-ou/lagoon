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
    private(set) var owner: String?
    private(set) var generation: UUID?

    func isCurrent(itemID: String, accountID: String?) -> Bool {
        guard let accountID, let owner, let generation,
              owner == TopShelfPublisher.accountOwner(accountID) else { return false }
        return TopShelfStore.accepts(owner: owner, generation: generation, itemID: itemID)
    }

    func clear() {
        pendingItemID = nil
        pendingDetailItemID = nil
        owner = nil
        generation = nil
    }

    /// URL contract shared with `LagoonTopShelf/ContentProvider.swift`:
    /// `lagoon://play/{itemId}` plays, `lagoon://item/{itemId}` opens the
    /// detail page. An unknown host is ignored rather than guessed at.
    func handle(_ url: URL) {
        guard url.scheme == "lagoon" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let owners = query.filter { $0.name == "owner" }
        let generations = query.filter { $0.name == "generation" }
        // Legacy unowned links cannot safely resolve after an account switch.
        guard owners.count == 1, generations.count == 1,
              let owner = owners.first?.value, owner.count == 64, owner.allSatisfy({ $0.isHexDigit }),
              let value = generations.first?.value, let generation = UUID(uuidString: value) else { return }
        let id = url.pathComponents.filter { $0 != "/" }.first
        guard let id, !id.isEmpty else { return }
        guard url.host() == "play" || url.host() == "item" else { return }
        clear()
        self.owner = owner
        self.generation = generation
        switch url.host() {
        case "play": pendingItemID = id
        case "item": pendingDetailItemID = id
        default: return
        }
    }
}

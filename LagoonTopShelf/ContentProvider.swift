import TVServices

/// Top Shelf carousel for Continue Watching (HEL-37).
///
/// The extension deliberately does **no networking and holds no
/// credentials**. The app writes a small snapshot into the shared App Group
/// container after each Home refresh, and this reads it back. That is why
/// there is no keychain access group here: sharing a token with an
/// extension is a bigger trust boundary than this feature needs, and
/// Jellyfin's `Items/{id}/Images/...` routes are unauthenticated anyway —
/// unlike the trickplay route, which is the one image endpoint that 401s
/// without credentials (see docs/jellyfin-api.md).
///
/// The item shape is duplicated from `TopShelfStore.Item` in the app rather
/// than shared: an app extension cannot import the app's module, and a
/// framework target purely for four fields would cost more than it saves.
/// Both sides are `Codable` over the same key names — change one, change
/// the other.
private struct TopShelfItem: Codable {
    let id: String
    let title: String
    let subtitle: String?
    let imageURLString: String?
    /// 0...1, or nil when the item has no resume position.
    let progress: Double?
}

class ContentProvider: TVTopShelfContentProvider {
    private let appGroupID = "group.ee.helop.lagoon"
    private let itemsKey = "topShelf.continueWatching"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let items = loadItems()
        // Returning nil leaves the system's default app banner in place,
        // which is the right look for a signed-out or freshly installed app
        // — better than an empty shelf.
        guard !items.isEmpty else { return nil }

        let sectionItems = items.map { item -> TVTopShelfSectionedItem in
            let entry = TVTopShelfSectionedItem(identifier: item.id)
            entry.title = item.title
            entry.imageShape = .hdtv
            if let string = item.imageURLString, let url = URL(string: string) {
                entry.setImageURL(url, for: .screenScale1x)
                entry.setImageURL(url, for: .screenScale2x)
            }
            if let progress = item.progress {
                entry.playbackProgress = min(max(progress, 0), 1)
            }
            // URL contract shared with LagoonApp.onOpenURL.
            if let url = URL(string: "lagoon://play/\(item.id)") {
                entry.displayAction = TVTopShelfAction(url: url)
                entry.playAction = TVTopShelfAction(url: url)
            }
            return entry
        }

        let section = TVTopShelfItemCollection(items: sectionItems)
        section.title = "Continue Watching"
        return TVTopShelfSectionedContent(sections: [section])
    }

    private func loadItems() -> [TopShelfItem] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: itemsKey),
              let items = try? JSONDecoder().decode([TopShelfItem].self, from: data)
        else { return [] }
        return items
    }
}

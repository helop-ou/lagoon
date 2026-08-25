import TVServices

/// Full-screen Top Shelf carousel for Continue Watching (HEL-37, HEL-119).
///
/// The extension deliberately does **no networking and holds no
/// credentials**. The app writes a snapshot and a set of composed JPEGs into
/// the shared App Group container after each Home refresh, and this reads
/// them back. That is why there is no keychain access group here: sharing a
/// token with an extension is a bigger trust boundary than this feature
/// needs.
///
/// **The carousel draws no title of its own.** `TVTopShelfCarouselItem`
/// inherits `playAction`, `displayAction` and `setImageURL`, and adds
/// `contextTitle`, `summary`, `genre` and `duration` — there is no `title`
/// property of the kind `TVTopShelfSectionedItem` has. The name of the thing
/// is therefore part of the artwork the app composed, which is also how the
/// Apple TV app does it.
///
/// The item shape is duplicated from `TopShelfStore.Item` in the app rather
/// than shared: an app extension cannot import the app's module, and a
/// framework target purely for these fields would cost more than it saves.
/// Both sides are `Codable` over the same key names — change one, change
/// the other.
private struct TopShelfItem: Codable {
    let id: String
    let title: String
    let context: String?
    let artwork2x: String?
    let artwork1x: String?
    let summary: String?
    let genre: String?
    let duration: Double?
    /// Raw `TVTopShelfCarouselItem.MediaOptions`, resolved by the app.
    let mediaOptions: UInt?
}

class ContentProvider: TVTopShelfContentProvider {
    private let appGroupID = "group.ee.helop.lagoon"
    private let itemsKey = "topShelf.continueWatching"
    private let artworkDirectory = "TopShelf"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let items = loadItems()
        // Returning nil leaves the static brand image in place, which is the
        // right look for a signed-out or freshly installed app and better
        // than an empty carousel.
        guard !items.isEmpty else { return nil }

        let carouselItems = items.compactMap(carouselItem(for:))
        guard !carouselItems.isEmpty else { return nil }

        // `.details` over `.actions`: Lagoon has a summary, a genre and a
        // runtime to show, and withholding them to keep the frame clean
        // would be throwing away the reason someone pauses on a title.
        return TVTopShelfCarouselContent(style: .details, items: carouselItems)
    }

    private func carouselItem(for item: TopShelfItem) -> TVTopShelfCarouselItem? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let directory = container.appending(path: artworkDirectory)

        let entry = TVTopShelfCarouselItem(identifier: item.id)
        // The line above the title. The app composes it, because which
        // episode this is and how much of it is left are library facts and
        // this process deliberately has no library.
        entry.contextTitle = item.context
        entry.summary = item.summary
        entry.genre = item.genre
        if let duration = item.duration, duration > 0 {
            entry.duration = duration
        }
        // 4K, HDR, Dolby Vision, Atmos. tvOS draws these itself; the app
        // resolved them from the media streams.
        if let options = item.mediaOptions {
            entry.mediaOptions = TVTopShelfCarouselItem.MediaOptions(rawValue: options)
        }

        // File URLs resolved against this process's own container: an
        // absolute path handed over by another process is not something to
        // trust, and the container id differs per install anyway.
        var hasImage = false
        if let name = item.artwork2x {
            entry.setImageURL(directory.appending(path: name), for: .screenScale2x)
            hasImage = true
        }
        if let name = item.artwork1x {
            entry.setImageURL(directory.appending(path: name), for: .screenScale1x)
            hasImage = true
        }
        // Without artwork there is no title either, since the title lives in
        // the image. An entry like that is worse than one fewer.
        guard hasImage else { return nil }

        // Two buttons, two different things. Play resumes; More Info opens
        // the detail page, which is what the carousel's second button is for.
        if let play = URL(string: "lagoon://play/\(item.id)") {
            entry.playAction = TVTopShelfAction(url: play)
        }
        if let detail = URL(string: "lagoon://item/\(item.id)") {
            entry.displayAction = TVTopShelfAction(url: detail)
        }
        return entry
    }

    private func loadItems() -> [TopShelfItem] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: itemsKey),
              let items = try? JSONDecoder().decode([TopShelfItem].self, from: data)
        else { return [] }
        return items
    }
}

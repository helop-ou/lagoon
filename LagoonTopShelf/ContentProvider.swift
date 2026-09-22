import OSLog
import TVServices

/// Shared with the app, so one predicate on a real Apple TV shows both sides.
/// Every failure here returns nil, which looks like an empty shelf, so log it.
///
///     log stream --predicate 'subsystem == "ee.helop.lagoon"'
private let log = Logger(subsystem: "ee.helop.lagoon", category: "topshelf")

/// Full-screen Top Shelf carousel for Continue Watching.
///
/// No networking and no credentials (so no keychain access group): the app
/// writes a snapshot and composed JPEGs to the App Group container, and this
/// reads them. The title is drawn into the artwork.
///
/// Mirrors `TopShelfStore.Item`, since an extension cannot import the app
/// module. Change both.
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

private struct TopShelfSnapshot: Decodable {
    let owner: String
    let generation: UUID
    let publishedAt: Date
    let items: [TopShelfItem]
}

class ContentProvider: TVTopShelfContentProvider {
    private let appGroupID = "group.ee.helop.lagoon"
    private let snapshotName = "snapshot-v2.json"
    /// Mirrors `TopShelfArtwork.containerSubpath` (which says why Caches).
    /// Change both.
    private let artworkDirectory = "Library/Caches/TopShelf"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        // Tells "never ran" apart from "ran and had nothing".
        log.info("loadTopShelfContent")

        guard let snapshot = loadSnapshot() else { return nil }
        let items = snapshot.items
        // Nil keeps the static brand image, better than an empty carousel.
        guard !items.isEmpty else {
            log.info("no snapshot: signed out, or the app has not published yet")
            return nil
        }

        let carouselItems = items.compactMap { carouselItem(for: $0, snapshot: snapshot) }
        guard !carouselItems.isEmpty else {
            log.error("\(items.count) items in the snapshot, none usable")
            return nil
        }
        log.info("returning \(carouselItems.count) of \(items.count) items")

        // `.details` shows the summary, genre and runtime. Recheck the
        // generation after building URLs, in case the app cleared or
        // replaced the snapshot meanwhile.
        guard loadSnapshot()?.generation == snapshot.generation else { return nil }
        return TVTopShelfCarouselContent(style: .details, items: carouselItems)
    }

    private func carouselItem(for item: TopShelfItem, snapshot: TopShelfSnapshot) -> TVTopShelfCarouselItem? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else {
            log.error("no App Group container — entitlement missing on the extension?")
            return nil
        }
        let directory = container.appending(path: artworkDirectory)

        let entry = TVTopShelfCarouselItem(identifier: "\(snapshot.owner):\(snapshot.generation):\(item.id)")
        entry.contextTitle = item.context
        entry.summary = item.summary
        entry.genre = item.genre
        if let duration = item.duration, duration > 0 {
            entry.duration = duration
        }
        if let options = item.mediaOptions {
            entry.mediaOptions = TVTopShelfCarouselItem.MediaOptions(rawValue: options)
        }

        // Resolve names against this process's own container, never an
        // absolute path from the app. Check each file exists: the snapshot
        // and images are written separately, and a URL to a missing file
        // draws a blank frame.
        var hasImage = false
        for (name, scale) in [
            (item.artwork2x, TVTopShelfItem.ImageTraits.screenScale2x),
            (item.artwork1x, TVTopShelfItem.ImageTraits.screenScale1x),
        ] {
            guard let name else { continue }
            let prefix = "\(snapshot.owner)-\(snapshot.generation.uuidString)/"
            guard name.hasPrefix(prefix), !name.contains(".."), name.split(separator: "/").count == 2 else { continue }
            let url = directory.appending(path: name)
            guard FileManager.default.fileExists(atPath: url.path) else {
                log.error("\(name, privacy: .public) is in the snapshot but not on disk")
                continue
            }
            entry.setImageURL(url, for: scale)
            hasImage = true
        }
        // No artwork means no title either; drop the entry.
        guard hasImage else { return nil }

        // Play resumes; More Info opens the detail page.
        if let play = actionURL("play", item: item, snapshot: snapshot) {
            entry.playAction = TVTopShelfAction(url: play)
        }
        if let detail = actionURL("item", item: item, snapshot: snapshot) {
            entry.displayAction = TVTopShelfAction(url: detail)
        }
        return entry
    }

    private func actionURL(_ action: String, item: TopShelfItem, snapshot: TopShelfSnapshot) -> URL? {
        var components = URLComponents()
        components.scheme = "lagoon"
        components.host = action
        components.path = "/\(item.id)"
        components.queryItems = [URLQueryItem(name: "owner", value: snapshot.owner),
                                 URLQueryItem(name: "generation", value: snapshot.generation.uuidString)]
        return components.url
    }

    private func loadSnapshot() -> TopShelfSnapshot? {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID),
              let data = try? Data(contentsOf: container.appending(path: artworkDirectory).appending(path: snapshotName)),
              let snapshot = try? JSONDecoder().decode(TopShelfSnapshot.self, from: data),
              snapshot.owner.count == 64, snapshot.owner.allSatisfy({ $0.isHexDigit }) else { return nil }
        return snapshot
    }
}

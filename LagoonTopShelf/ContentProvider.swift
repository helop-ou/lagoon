import OSLog
import TVServices

/// Shares `ee.helop.lagoon`/`topshelf` with the app, so one predicate on a
/// real Apple TV shows the app publishing and this process reading:
///
///     log stream --predicate 'subsystem == "ee.helop.lagoon"'
///
/// Permanent rather than debug scaffolding. This process has no UI, runs only
/// when the Home screen asks, and every failure path here returns nil — which
/// looks exactly like an empty Continue Watching from the sofa.
private let log = Logger(subsystem: "ee.helop.lagoon", category: "topshelf")

/// Full-screen Top Shelf carousel for Continue Watching.
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

private struct TopShelfSnapshot: Decodable {
    let owner: String
    let generation: UUID
    let publishedAt: Date
    let items: [TopShelfItem]
}

class ContentProvider: TVTopShelfContentProvider {
    private let appGroupID = "group.ee.helop.lagoon"
    private let snapshotName = "snapshot-v2.json"
    /// Mirrors `TopShelfArtwork.containerSubpath`, which explains why it is
    /// under Caches: tvOS gives an app 500 KB of persistent local storage and
    /// requires everything else to be purgeable, so a real Apple TV refuses
    /// the write anywhere else. Change one, change the other.
    private let artworkDirectory = "Library/Caches/TopShelf"

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        // First line, so the log distinguishes "the extension never ran" from
        // "it ran and had nothing" — the whole of debugging turned on that.
        log.info("loadTopShelfContent")

        guard let snapshot = loadSnapshot() else { return nil }
        let items = snapshot.items
        // Returning nil leaves the static brand image in place, which is the
        // right look for a signed-out or freshly installed app and better
        // than an empty carousel.
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

        // `.details` over `.actions`: Lagoon has a summary, a genre and a
        // runtime to show, and withholding them to keep the frame clean
        // would be throwing away the reason someone pauses on a title.
        // Recheck after assembling file URLs so a clear/commit in the other
        // process cannot make a snapshot we already read current again.
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
        //
        // Existence is checked rather than assumed. The app writes the
        // snapshot and the images separately, so a run interrupted between
        // the two leaves a name pointing at nothing, and handing tvOS a URL
        // to a missing file draws a blank frame instead of falling back.
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
        // Without artwork there is no title either, since the title lives in
        // the image. An entry like that is worse than one fewer.
        guard hasImage else { return nil }

        // Two buttons, two different things. Play resumes; More Info opens
        // the detail page, which is what the carousel's second button is for.
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

import Foundation
#if os(tvOS)
import TVServices
import UIKit
#endif

/// Publishes a Continue Watching snapshot for the Top Shelf extension
/// (HEL-37), now as a full-screen carousel (HEL-119).
///
/// The extension holds **no credentials and does no networking** — it draws
/// whatever the app last wrote here. That was true when the payload carried
/// remote image URLs and is more true now: the app composes finished JPEGs
/// into the shared container and the extension only reads files.
enum TopShelfStore {
    /// Mirrored by `TopShelfItem` in `LagoonTopShelf/ContentProvider.swift`.
    /// An app extension cannot import the app's module, and a framework
    /// target for a handful of fields would cost more than it saves, so both
    /// sides encode the same key names instead. **Change one, change the
    /// other.**
    nonisolated struct Item: Codable {
        let id: String
        let title: String
        let subtitle: String?
        /// File name inside the shared container's `TopShelf` directory, at
        /// @2x. The extension resolves it against its own container URL
        /// rather than trusting an absolute path from another process.
        let artwork2x: String?
        let artwork1x: String?
        let summary: String?
        let genre: String?
        /// Seconds, for the carousel's duration badge.
        let duration: Double?
        /// 0...1, or nil when the item has no resume position.
        let progress: Double?
    }

    static let appGroupID = "group.ee.helop.lagoon"
    private static let itemsKey = "topShelf.continueWatching"
    /// Apple asks for three to eight in a banner sequence, and each one costs
    /// a 4K composite, so this stays at the low end of useful.
    private static let limit = 5

    #if os(tvOS)
    /// Composes artwork and publishes the snapshot. Runs off the main actor:
    /// five 3840x2160 composites is not work to do while the UI waits.
    static func publish(_ items: [MediaItem], client: JellyfinClient) {
        let sources = Array(items.prefix(limit))
        guard !sources.isEmpty else { return }
        Task.detached(priority: .utility) {
            await build(sources, client: client)
        }
    }

    private static func build(_ items: [MediaItem], client: JellyfinClient) async {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let directory = TopShelfArtwork.directoryURL(appGroupID: appGroupID)
        else { return }

        var payload: [Item] = []
        var written: Set<String> = []

        for item in items {
            let backdropURL = client.imageURL(
                for: item,
                kind: .backdrop,
                maxWidth: Int(TopShelfArtwork.scale2x.width)
            )
            let logoURL = client.imageURL(for: item, kind: .logo, maxWidth: 1200)
            // A title with no backdrop cannot make a full-screen image worth
            // showing, so it is left out rather than rendered onto black.
            guard let backdropURL, let backdrop = await image(at: backdropURL) else { continue }
            var logo: UIImage?
            if let logoURL { logo = await image(at: logoURL) }

            let names = write(
                backdrop: backdrop,
                logo: logo,
                title: item.railTitle,
                id: item.id,
                into: directory
            )
            guard let names else { continue }
            written.insert(names.twoX)
            written.insert(names.oneX)

            payload.append(
                Item(
                    id: item.id,
                    title: item.railTitle,
                    subtitle: item.railSubtitle,
                    artwork2x: names.twoX,
                    artwork1x: names.oneX,
                    summary: item.overview,
                    genre: item.genres?.first,
                    duration: item.runTimeTicks.map(Ticks.seconds),
                    progress: item.playbackProgress
                )
            )
        }

        guard !payload.isEmpty else { return }
        TopShelfArtwork.removeArtwork(notIn: written, appGroupID: appGroupID)
        defaults.set(try? JSONEncoder().encode(payload), forKey: itemsKey)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func write(
        backdrop: UIImage,
        logo: UIImage?,
        title: String,
        id: String,
        into directory: URL
    ) -> (twoX: String, oneX: String)? {
        let sizes = [
            ("\(id)@2x.jpg", TopShelfArtwork.scale2x),
            ("\(id)@1x.jpg", TopShelfArtwork.scale1x),
        ]
        for (name, size) in sizes {
            let composed = TopShelfArtwork.compose(
                backdrop: backdrop,
                logo: logo,
                title: title,
                size: size
            )
            guard let data = composed.jpegData(compressionQuality: 0.9) else { return nil }
            do {
                try data.write(to: directory.appending(path: name), options: .atomic)
            } catch {
                return nil
            }
        }
        return (sizes[0].0, sizes[1].0)
    }

    private static func image(at url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return UIImage(data: data)
    }
    #else
    static func publish(_ items: [MediaItem], client: JellyfinClient) {}
    #endif

    /// Signing out or switching account has to wipe this. The Top Shelf sits
    /// on the TV's home screen where anyone in the room can read it, so
    /// leaving the previous user's viewing there would be a small but real
    /// privacy leak — and HEL-38 made switching easy, which makes it
    /// reachable. The composed artwork goes with it, since a 4K still of what
    /// someone was watching is the same leak in picture form.
    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: itemsKey)
        TopShelfArtwork.removeArtwork(notIn: [], appGroupID: appGroupID)
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }
}

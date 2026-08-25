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
        /// What the artwork says. The extension never draws it — the title is
        /// burned into the image — but a payload of nothing but hashes is
        /// unreadable when something goes wrong, and this is the field that
        /// says which title a row is.
        let title: String
        /// The line above the title: why this is on the shelf, and which
        /// episode or how much is left.
        let context: String?
        /// File name inside the shared container's `TopShelf` directory, at
        /// @2x. The extension resolves it against its own container URL
        /// rather than trusting an absolute path from another process.
        let artwork2x: String?
        let artwork1x: String?
        let summary: String?
        let genre: String?
        /// Seconds, for the carousel's duration badge.
        let duration: Double?
        /// Raw `TVTopShelfCarouselItem.MediaOptions`. Resolved here because
        /// the extension has no library access and no business deciding what
        /// counts as 4K.
        let mediaOptions: UInt?
    }

    static let appGroupID = "group.ee.helop.lagoon"
    private static let itemsKey = "topShelf.continueWatching"
    /// The HIG's "three to eight" is guidance for a **scrolling banner**, not
    /// this layout, and neither the HIG nor `TVTopShelfCarouselContent` puts a
    /// number on a carousel. Eight is chosen for the reason Apple gives for
    /// the banner ceiling — the carousel is swipe-navigated and wraps, so a
    /// long one buries the title you wanted — and artwork is now reused
    /// between publishes, so the extra items cost nothing on a repeat visit.
    private static let limit = 8

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
            let names = artworkNames(for: item.id)
            // Composing is two 4K-class renders and two image downloads, and
            // `publish` runs on every return to Home, not just on a change.
            // Artwork for a given title never varies, so anything already in
            // the container is reused and the work is skipped entirely. The
            // payload below is still rebuilt each time, which is what keeps
            // "42 min left" honest.
            if !artworkExists(names, in: directory) {
                guard await compose(item, client: client, as: names, into: directory) else { continue }
            }
            written.insert(names.twoX)
            written.insert(names.oneX)

            payload.append(
                Item(
                    id: item.id,
                    title: item.railTitle,
                    context: item.topShelfContext,
                    artwork2x: names.twoX,
                    artwork1x: names.oneX,
                    summary: item.overview,
                    genre: item.genres?.first,
                    duration: item.runTimeTicks.map(Ticks.seconds),
                    mediaOptions: item.topShelfMediaOptions
                )
            )
        }

        guard !payload.isEmpty else { return }
        TopShelfArtwork.removeArtwork(notIn: written, appGroupID: appGroupID)
        defaults.set(try? JSONEncoder().encode(payload), forKey: itemsKey)
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static func artworkNames(for id: String) -> (twoX: String, oneX: String) {
        ("\(id)@2x.jpg", "\(id)@1x.jpg")
    }

    private static func artworkExists(
        _ names: (twoX: String, oneX: String),
        in directory: URL
    ) -> Bool {
        let manager = FileManager.default
        return manager.fileExists(atPath: directory.appending(path: names.twoX).path)
            && manager.fileExists(atPath: directory.appending(path: names.oneX).path)
    }

    /// Fetches the source images and writes both scales. False when the title
    /// cannot make a full-screen image worth showing, in which case it is left
    /// off the shelf rather than rendered onto black.
    private static func compose(
        _ item: MediaItem,
        client: JellyfinClient,
        as names: (twoX: String, oneX: String),
        into directory: URL
    ) async -> Bool {
        let backdropURL = client.imageURL(
            for: item,
            kind: .backdrop,
            maxWidth: Int(TopShelfArtwork.scale2x.width)
        )
        guard let backdropURL, let backdrop = await image(at: backdropURL) else { return false }
        var logo: UIImage?
        if let logoURL = client.imageURL(for: item, kind: .logo, maxWidth: 1200) {
            logo = await image(at: logoURL)
        }

        for (name, size) in [(names.twoX, TopShelfArtwork.scale2x), (names.oneX, TopShelfArtwork.scale1x)] {
            let composed = TopShelfArtwork.compose(
                backdrop: backdrop,
                logo: logo,
                title: item.railTitle,
                size: size
            )
            guard let data = composed.jpegData(compressionQuality: 0.9) else { return false }
            do {
                try data.write(to: directory.appending(path: name), options: .atomic)
            } catch {
                return false
            }
        }
        return true
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

#if os(tvOS)
extension MediaItem {
    /// The carousel's one line of app-supplied text, above the title that
    /// lives in the artwork.
    ///
    /// `contextTitle` is documented as "why this item is being shown", so the
    /// framing stays and the identifying detail is appended. Episodes name the
    /// episode, because `railTitle` is the *series* for an episode and without
    /// this the shelf cannot say which one you are part way through. Anything
    /// else says how much is left, which is the fact a resume shelf exists to
    /// answer.
    var topShelfContext: String {
        let framing = "Continue Watching"
        if let episodeLabel { return "\(framing) · \(episodeLabel)" }
        if let remaining = topShelfTimeRemaining { return "\(framing) · \(remaining)" }
        return framing
    }

    private var topShelfTimeRemaining: String? {
        guard let runTimeTicks, let progress = playbackProgress else { return nil }
        let minutes = Int(Ticks.seconds(runTimeTicks) * (1 - progress) / 60)
        guard minutes > 0 else { return nil }
        if minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) min left" }
        return "\(minutes) min left"
    }

    /// The capability badges tvOS draws for a carousel item, from the same
    /// stream facts the detail page and the player's Info panel read, so all
    /// three agree on what counts as 4K or Dolby Vision (HEL-46).
    ///
    /// Nil rather than zero when the server told us nothing about the streams,
    /// so an empty set is never mistaken for "checked, and it is plain SDR".
    var topShelfMediaOptions: UInt? {
        guard let streams = mediaSources?.first?.mediaStreams, !streams.isEmpty else { return nil }
        var options: TVTopShelfCarouselItem.MediaOptions = []

        if let video = streams.first(where: { $0.type == "Video" }) {
            if let width = video.width {
                // Apple offers only HD and 4K, so 720p and 1080p both land on
                // HD and anything below earns no badge at all.
                switch MediaQuality.resolutionClass(width: width) {
                case "4K": options.insert(.videoResolution4K)
                case "1080p", "720p": options.insert(.videoResolutionHD)
                default: break
                }
            }
            switch video.videoRangeType {
            case let range? where range.hasPrefix("DOVI"): options.insert(.videoColorSpaceDolbyVision)
            case let range? where range != "SDR": options.insert(.videoColorSpaceHDR)
            default: break
            }
        }

        let audio = streams.filter { $0.type == "Audio" }
        if audio.contains(where: { $0.profile?.localizedCaseInsensitiveContains("atmos") == true }) {
            options.insert(.audioDolbyAtmos)
        }
        if streams.contains(where: { $0.type == "Subtitle" && $0.isHearingImpaired == true }) {
            options.insert(.audioTranscriptionSDH)
        }

        return options.rawValue
    }
}
#endif

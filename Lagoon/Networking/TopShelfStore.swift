import Foundation
import OSLog
#if os(tvOS)
import TVServices
import UIKit
#endif

/// Both halves of the Top Shelf log to `ee.helop.lagoon`/`topshelf`, so one
/// predicate on a real Apple TV shows the app publishing and the extension
/// reading. This is not debug scaffolding: the shelf is only observable on
/// hardware, in a process with no UI, and three rounds of HEL-119 were spent
/// guessing at silent nil returns.
///
///     log stream --predicate 'subsystem == "ee.helop.lagoon"'
private let log = Logger(subsystem: "ee.helop.lagoon", category: "topshelf")

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
    private static let publishedAtKey = "topShelf.publishedAt"
    private static let attemptedAtKey = "topShelf.attemptedAt"
    private static let lastResultKey = "topShelf.lastResult"

    /// Records how a publish attempt ended, successfully or not.
    ///
    /// Every failure in this file is a silent early return, and on the Home
    /// screen they all look identical: the static brand image. Writing the
    /// reason where Settings can read it is the difference between "the shelf
    /// is empty" and knowing which of six conditions was not met, without a
    /// Mac attached to the Apple TV (HEL-119).
    private static func record(_ result: String) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(result, forKey: lastResultKey)
        defaults.set(Date.now.timeIntervalSince1970, forKey: attemptedAtKey)
    }

    /// The HIG's "three to eight" is guidance for a **scrolling banner**, not
    /// this layout, and neither the HIG nor `TVTopShelfCarouselContent` puts a
    /// number on a carousel. Eight is chosen for the reason Apple gives for
    /// the banner ceiling — the carousel is swipe-navigated and wraps, so a
    /// long one buries the title you wanted — and artwork is now reused
    /// between publishes, so the extra items cost nothing on a repeat visit.
    private static let limit = 8

    #if os(tvOS)
    /// Composes artwork and publishes the snapshot. The expensive part runs
    /// off the main actor; see `render`.
    static func publish(_ items: [MediaItem], client: JellyfinClient) {
        let sources = Array(items.prefix(limit))
        guard !sources.isEmpty else {
            // Nothing in Continue Watching is a legitimate state, and the
            // shelf correctly falls back to the static brand image — but it
            // looks identical to a broken extension from the sofa, so say so.
            log.info("nothing to publish: Continue Watching is empty")
            record("Continue Watching is empty")
            return
        }
        Task.detached(priority: .utility) {
            await build(sources, client: client)
        }
    }

    /// Publishes if the shelf has nothing to show, fetching Continue Watching
    /// itself rather than waiting to be handed it.
    ///
    /// Every other path here hangs off Home: `load` publishes only if it got
    /// all the way through without throwing, and `refreshProgress` gives up
    /// early unless a load already succeeded. So a single failed load on a
    /// cold start left the shelf empty until something happened to drive Home
    /// again, and nothing retried. This runs on activation and is a no-op the
    /// moment there is anything published, which is the common case.
    static func publishIfEmpty(client: JellyfinClient) {
        let current = status()
        guard current.containerAvailable else {
            log.error("cannot self-heal: no App Group container")
            record("Shared container unavailable")
            return
        }
        guard current.publishedCount == 0 || current.artworkCount == 0 else { return }
        log.info("shelf is empty (\(current.publishedCount) titles, \(current.artworkCount) files); fetching")
        Task.detached(priority: .utility) {
            do {
                let resume = try await client.resumeItems()
                guard !resume.isEmpty else {
                    log.info("self-heal found nothing in Continue Watching")
                    record("Continue Watching is empty")
                    return
                }
                await build(Array(resume.prefix(limit)), client: client)
            } catch {
                log.error("self-heal could not reach the server: \(error, privacy: .public)")
                record("Could not reach the server: \(error.localizedDescription)")
            }
        }
    }

    private static func build(_ items: [MediaItem], client: JellyfinClient) async {
        guard let defaults = UserDefaults(suiteName: appGroupID) else {
            log.error("no App Group defaults for \(appGroupID, privacy: .public) — entitlement missing?")
            return
        }
        guard let directory = TopShelfArtwork.directoryURL(appGroupID: appGroupID) else {
            log.error("no App Group container — entitlement missing?")
            record("Shared container unavailable")
            return
        }
        record("Started for \(items.count) titles")
        // A layout change makes every previously composed image wrong, and
        // the cache below would otherwise serve build 56's bottom-left
        // artwork forever to anyone upgrading.
        TopShelfArtwork.discardArtworkFromEarlierLayouts(defaults: defaults, appGroupID: appGroupID)

        var payload: [Item] = []
        var written: Set<String> = []
        var composed = 0
        var lastFailure: String?

        for item in items {
            let names = artworkNames(for: item.id)
            // Composing is two 4K-class renders and two image downloads, and
            // `publish` runs on every return to Home, not just on a change.
            // Artwork for a given title never varies, so anything already in
            // the container is reused and the work is skipped entirely. The
            // payload below is still rebuilt each time, which is what keeps
            // "42 min left" honest.
            if !artworkExists(names, in: directory) {
                if let failure = await compose(item, client: client, as: names, into: directory) {
                    log.error("\(item.id, privacy: .public): \(failure, privacy: .public)")
                    lastFailure = failure
                    continue
                }
                composed += 1
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
            // Written after **every** item rather than once at the end. A
            // first run on a real Apple TV is eight backdrop downloads and
            // sixteen 4K-class renders inside a detached utility task, and if
            // the app is suspended or jetsammed part way through, publishing
            // only at the end would leave the shelf with nothing at all
            // instead of the titles already finished.
            defaults.set(try? JSONEncoder().encode(payload), forKey: itemsKey)
        }

        guard !payload.isEmpty else {
            log.error("nothing publishable out of \(items.count) items")
            record("No artwork for any of \(items.count) titles: \(lastFailure ?? "unknown")")
            return
        }
        TopShelfArtwork.removeArtwork(notIn: written, appGroupID: appGroupID)
        defaults.set(Date.now.timeIntervalSince1970, forKey: publishedAtKey)
        record("Published \(payload.count) of \(items.count) titles, \(composed) newly drawn")
        TVTopShelfContentProvider.topShelfContentDidChange()
        log.info("published \(payload.count) of \(items.count) items, \(composed) newly composed")
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
    /// Nil on success, or the step that failed.
    ///
    /// Named steps rather than a bool, because every one of these is
    /// invisible from the sofa and "no artwork could be built" was one round
    /// of diagnosis short of an answer (HEL-119).
    private static func compose(
        _ item: MediaItem,
        client: JellyfinClient,
        as names: (twoX: String, oneX: String),
        into directory: URL
    ) async -> String? {
        guard let backdropURL = client.imageURL(
            for: item,
            kind: .backdrop,
            maxWidth: Int(TopShelfArtwork.scale2x.width)
        ) else { return "no backdrop image on the server" }
        guard let backdrop = await data(at: backdropURL) else {
            return "backdrop would not download"
        }
        var logo: Data?
        if let logoURL = client.imageURL(for: item, kind: .logo, maxWidth: 1200) {
            logo = await data(at: logoURL)
        }
        // Read on this actor, since MediaItem's helpers are isolated too.
        let title = item.railTitle

        return await Task.detached(priority: .utility) {
            render(backdrop: backdrop, logo: logo, title: title, as: names, into: directory)
        }.value
    }

    /// Decodes the source images, draws both composites and writes them.
    ///
    /// `nonisolated`, and called through `Task.detached`, because this is a
    /// second or more of synchronous CPU work per title: a 4K backdrop decode
    /// plus a 3840x2160 and a 1920x1080 render. The target builds with
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so everything in this file
    /// is main-actor isolated unless it says otherwise — which meant the
    /// `Task.detached` above hopped straight back and did all of it on the
    /// main thread. That is invisible on a Mac and long enough on an Apple TV
    /// to stall the UI and interest the watchdog (HEL-119).
    nonisolated private static func render(
        backdrop: Data,
        logo: Data?,
        title: String,
        as names: (twoX: String, oneX: String),
        into directory: URL
    ) -> String? {
        guard let backdropImage = UIImage(data: backdrop) else {
            return "backdrop would not decode"
        }
        let logoImage = logo.flatMap { UIImage(data: $0) }

        for (name, size) in [(names.twoX, TopShelfArtwork.scale2x), (names.oneX, TopShelfArtwork.scale1x)] {
            let composed = TopShelfArtwork.compose(
                backdrop: backdropImage,
                logo: logoImage,
                title: title,
                size: size
            )
            // Nil here is what an extended-range bitmap produces, which is
            // how the HDR format bug presented.
            guard let jpeg = composed.jpegData(compressionQuality: 0.9) else {
                return "composite would not encode as JPEG"
            }
            do {
                try jpeg.write(to: directory.appending(path: name), options: .atomic)
            } catch {
                return "could not write to the shared container: \(error.localizedDescription)"
            }
        }
        return nil
    }

    /// Bytes rather than a `UIImage`: decoding belongs with the rendering, off
    /// this actor. The download itself suspends rather than blocks, so it is
    /// no burden here.
    private static func data(at url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
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
    /// What the app has actually put in the shared container, for Settings →
    /// Advanced.
    ///
    /// The Top Shelf is only observable on a real Apple TV, from the Home
    /// screen, and an empty shelf looks identical whether Continue Watching
    /// is empty, the app never finished publishing, or the App Group is not
    /// provisioned. Reading this from the sofa separates those without a Mac
    /// attached (HEL-119).
    nonisolated struct Status {
        let containerAvailable: Bool
        let publishedCount: Int
        let artworkCount: Int
        let lastPublished: Date?
        let lastAttempt: Date?
        /// How the last attempt ended. Nil when none has run in this install,
        /// which is itself the answer: nothing is calling `publish`.
        let lastResult: String?
    }

    static func status() -> Status {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let directory = TopShelfArtwork.directoryURL(appGroupID: appGroupID)
        else {
            return Status(
                containerAvailable: false,
                publishedCount: 0,
                artworkCount: 0,
                lastPublished: nil,
                lastAttempt: nil,
                lastResult: nil
            )
        }
        let published = (defaults.data(forKey: itemsKey)
            .flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []).count
        let artwork = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.count ?? 0
        let publishedStamp = defaults.double(forKey: publishedAtKey)
        let attemptedStamp = defaults.double(forKey: attemptedAtKey)
        return Status(
            containerAvailable: true,
            publishedCount: published,
            artworkCount: artwork,
            lastPublished: publishedStamp > 0 ? Date(timeIntervalSince1970: publishedStamp) : nil,
            lastAttempt: attemptedStamp > 0 ? Date(timeIntervalSince1970: attemptedStamp) : nil,
            lastResult: defaults.string(forKey: lastResultKey)
        )
    }

    static func clear() {
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: itemsKey)
        UserDefaults(suiteName: appGroupID)?.removeObject(forKey: publishedAtKey)
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

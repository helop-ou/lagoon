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
    nonisolated struct Item: Codable, Equatable {
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
    private static let publisher: TopShelfPublisher? = {
        guard let directory = TopShelfArtwork.directoryURL(appGroupID: appGroupID) else { return nil }
        // The old payload has no owner and must never be read after upgrade.
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.removeObject(forKey: "topShelf.continueWatching")
        defaults?.removeObject(forKey: "topShelf.publishedAt")
        return TopShelfPublisher(directory: directory) {
            #if os(tvOS)
            TVTopShelfContentProvider.topShelfContentDidChange()
            #endif
        }
    }()

    static func activate(accountID: String?) { publisher?.activate(accountID: accountID) }
    static func clear() { publisher?.clear() }

    static func accepts(owner: String, generation: UUID, itemID: String) -> Bool {
        publisher?.accepts(owner: owner, generation: generation, itemID: itemID) == true
    }

    #if os(tvOS)
    private static let limit = 8

    /// Capture URLs, metadata and session identity before the first await.
    /// No renderer consults the mutable active Jellyfin client.
    private struct Source {
        let item: MediaItem
        let backdrop: URL?
        let logo: URL?
        let name: String
    }

    private static func sources(_ items: [MediaItem], client: JellyfinClient) -> [Source] {
        items.prefix(limit).map { item in
            let backdrop = client.imageURL(for: item, kind: .backdrop, maxWidth: Int(TopShelfArtwork.scale2x.width))
            let logo = client.imageURL(for: item, kind: .logo, maxWidth: 1200)
            // Include account identity and presentation inputs; identical IDs
            // from different servers must not share artwork.
            let key = "\(client.sessionIdentity?.serverURL.absoluteString ?? "")|\(client.userId ?? "")|\(item.id)|\(item.railTitle)|\(backdrop?.absoluteString ?? "")|\(logo?.absoluteString ?? "")|layout-\(TopShelfArtwork.layoutVersion)"
            return Source(item: item, backdrop: backdrop, logo: logo, name: TopShelfPublisher.accountOwner(key))
        }
    }

    static func publish(_ items: [MediaItem], client: JellyfinClient,
                        identity: JellyfinClient.SessionIdentity?) {
        guard let identity, identity == client.sessionIdentity else { return }
        let owner = TopShelfPublisher.accountOwner("\(identity.serverURL.absoluteString)|\(identity.userId)")
        let captured = sources(items, client: client)
        publisher?.publish(owner: owner) { stage, previous in
            try await build(captured, stage: stage, previous: previous)
        }
    }

    static func publishIfEmpty(client: JellyfinClient) {
        guard let identity = client.sessionIdentity, let publisher,
              publisher.snapshot?.items.isEmpty != false || status().artworkCount == 0 else { return }
        let owner = TopShelfPublisher.accountOwner("\(identity.serverURL.absoluteString)|\(identity.userId)")
        let captured = client.sessionSnapshot()
        publisher.publish(owner: owner) { stage, previous in
            let resume = try await captured.resumeItems()
            try Task.checkCancellation()
            return try await build(sources(resume, client: captured), stage: stage, previous: previous)
        }
    }

    private static func build(_ sources: [Source], stage: URL,
                              previous: TopShelfPublisher.Snapshot?) async throws -> [Item] {
        var payload: [Item] = []
        for source in sources {
            try Task.checkCancellation()
            let item = source.item
            let names = (twoX: "\(source.name)@2x.jpg", oneX: "\(source.name)@1x.jpg")
            var reused = false
            if let old = previous?.items.first(where: { $0.id == item.id }),
               let twoX = old.artwork2x, let oneX = old.artwork1x,
               URL(fileURLWithPath: twoX).lastPathComponent == names.twoX,
               URL(fileURLWithPath: oneX).lastPathComponent == names.oneX {
                do {
                    let root = stage.deletingLastPathComponent()
                    try FileManager.default.copyItem(at: root.appendingPathComponent(twoX), to: stage.appendingPathComponent(names.twoX))
                    try FileManager.default.copyItem(at: root.appendingPathComponent(oneX), to: stage.appendingPathComponent(names.oneX))
                    reused = true
                } catch {}
            }
            if !reused {
                guard let url = source.backdrop, let backdrop = await data(at: url) else { continue }
                try Task.checkCancellation()
                var logo: Data?
                if let url = source.logo { logo = await data(at: url) }
                try Task.checkCancellation()
                let title = item.railTitle
                let failure = await Task.detached(priority: .utility) {
                    render(backdrop: backdrop, logo: logo, title: title, as: names, into: stage)
                }.value
                try Task.checkCancellation()
                if failure != nil { continue }
            }
            payload.append(Item(id: item.id, title: item.railTitle, context: item.topShelfContext,
                                artwork2x: "\(stage.lastPathComponent)/\(names.twoX)",
                                artwork1x: "\(stage.lastPathComponent)/\(names.oneX)",
                                summary: item.overview, genre: item.genres?.first,
                                duration: item.runTimeTicks.map(Ticks.seconds), mediaOptions: item.topShelfMediaOptions))
        }
        // Failed artwork is not an authoritative empty library response.
        if !sources.isEmpty && payload.isEmpty { throw URLError(.cannotDecodeContentData) }
        return payload
    }

    nonisolated private static func render(backdrop: Data, logo: Data?, title: String,
                                           as names: (twoX: String, oneX: String), into directory: URL) -> String? {
        guard let backdropImage = UIImage(data: backdrop) else { return "backdrop would not decode" }
        let logoImage = logo.flatMap { UIImage(data: $0) }
        for (name, size) in [(names.twoX, TopShelfArtwork.scale2x), (names.oneX, TopShelfArtwork.scale1x)] {
            let composed = TopShelfArtwork.compose(backdrop: backdropImage, logo: logoImage, title: title, size: size)
            guard let jpeg = composed.jpegData(compressionQuality: 0.9) else { return "composite would not encode" }
            do { try jpeg.write(to: directory.appendingPathComponent(name), options: .atomic) }
            catch { return "could not write artwork" }
        }
        return nil
    }

    private static func data(at url: URL) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
    #else
    static func publish(_ items: [MediaItem], client: JellyfinClient, identity: JellyfinClient.SessionIdentity?) {}
    #endif

    nonisolated struct Status {
        let containerAvailable: Bool
        let publishedCount: Int
        let artworkCount: Int
        let lastPublished: Date?
        let lastAttempt: Date?
        let lastResult: String?
    }

    static func status() -> Status {
        let snapshot = publisher?.snapshot
        let artwork = snapshot?.items.reduce(0) { count, item in
            count + [item.artwork1x, item.artwork2x].compactMap { $0 }.filter { name in
                guard let directory = publisher?.directory else { return false }
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            }.count
        } ?? 0
        return Status(containerAvailable: publisher != nil, publishedCount: snapshot?.items.count ?? 0,
                      artworkCount: artwork, lastPublished: snapshot?.publishedAt,
                      lastAttempt: publisher?.lastAttempt, lastResult: publisher?.lastResult)
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

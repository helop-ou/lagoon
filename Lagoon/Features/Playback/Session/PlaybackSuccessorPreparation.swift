import Foundation
import LagoonEngine

/// Negotiates the next episode and hands the result to the engine to warm.
/// Network work never retains the controller or the outgoing engine, and a
/// late or cancelled answer never publishes over its replacement.
@MainActor
final class PlaybackSuccessorPreparation {
    struct PreparedPlayback {
        let mediaID: String
        let info: PlaybackInfoResponse
        let source: MediaSource
        let streamURL: URL
        let method: PlayMethod
        let offer: PlaybackOffer
    }

    /// Injected so the generation rules can be tested without an engine.
    struct Staging {
        /// Open a cache scope for this item, warming it when asked.
        var stage: @MainActor (PreparedPlayback, _ warms: Bool) -> Void
        /// The handoff is starting: stop warming, keep what was fetched.
        var endWarming: @MainActor () -> Void
        /// Drop the scope staged for this item, and only for this item.
        var discard: @MainActor (_ itemID: String) -> Void

        static let none = Staging(stage: { _, _ in }, endWarming: {}, discard: { _ in })
    }

    /// The item, the client and the bitrate ceiling the viewer accepted, if any.
    typealias Negotiation = @MainActor (String, JellyfinClient, Int?) async throws -> PreparedPlayback?

    private let negotiate: Negotiation
    private var staging = Staging.none
    private var generation = 0
    private var preparationTask: Task<PreparedPlayback?, Never>?
    private var prepared: PreparedPlayback?
    private var itemID: String?
    /// The ceiling the preparation was negotiated under.
    private var maxBitrate: Int?
    private var allowsWarming = false

    var isPreparing: Bool { preparationTask != nil }
    var hasPreparation: Bool { isPreparing || prepared != nil }

    init(negotiate: @escaping Negotiation = PlaybackSuccessorPreparation.negotiate) {
        self.negotiate = negotiate
    }

    isolated deinit {
        preparationTask?.cancel()
        if let itemID { staging.discard(itemID) }
    }

    /// `maxBitrate` is the session's ceiling: a lower quality the viewer
    /// accepted holds for the next item too.
    func prepare(
        itemID: String,
        client: JellyfinClient,
        maxBitrate: Int?,
        staging: Staging,
        warms: Bool
    ) {
        // One made under another ceiling is a stream the viewer has since
        // turned down.
        if hasPreparation, self.maxBitrate != maxBitrate { cancel() }
        guard !hasPreparation else { return }
        generation &+= 1
        let generation = generation
        self.itemID = itemID
        self.maxBitrate = maxBitrate
        self.staging = staging
        self.allowsWarming = warms
        let negotiate = negotiate
        preparationTask = Task { [weak self] in
            defer { self?.finishPreparation(generation: generation) }
            do {
                guard let result = try await negotiate(itemID, client, maxBitrate),
                      !Task.isCancelled,
                      let self, self.generation == generation else { return nil }
                // Read the flag now: a handoff that began meanwhile has given up its
                // warm-up, and must not have one started behind it.
                self.staging.stage(result, self.allowsWarming)
                self.prepared = result
                return result
            } catch {
                return nil
            }
        }
    }

    /// A ready result stays usable after its task ends. A running negotiation
    /// finishes, but skips the warm-up: accepting Up Next must not wait on it.
    func preparedForHandoff() async -> PreparedPlayback? {
        let generation = generation
        allowsWarming = false
        staging.endWarming()
        let result: PreparedPlayback?
        if let prepared {
            result = prepared
        } else {
            result = await preparationTask?.value
        }
        guard self.generation == generation, !Task.isCancelled else { return nil }
        preparationTask = nil
        prepared = nil
        return result
    }

    /// Discard synchronously before a replacement stages its scope. Late
    /// cancelled work, even for the same item ID, must never clear the new task
    /// or scope.
    func cancel() {
        generation &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        prepared = nil
        allowsWarming = false
        if let itemID { staging.discard(itemID) }
        itemID = nil
        staging = .none
    }

    private func finishPreparation(generation: Int) {
        guard self.generation == generation else { return }
        preparationTask = nil
    }

    static func negotiate(
        itemID: String, client: JellyfinClient, maxBitrate: Int?
    ) async throws -> PreparedPlayback? {
        let (info, offer) = try await client.negotiate(itemId: itemID, maxBitrate: maxBitrate)
        guard !Task.isCancelled,
              info.errorCode == nil,
              let source = info.mediaSources.first else { return nil }
        // Disc images and refused Dolby Vision negotiate their own rung at
        // playback start.
        let layout = PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType)
        guard !layout.isDisc, DolbyVisionBaseLayer.directPlayRefusal(for: source) == nil else { return nil }
        let (url, method) = try client.streamURL(itemId: itemID, source: source)
        return PreparedPlayback(
            mediaID: itemID, info: info, source: source, streamURL: url, method: method, offer: offer
        )
    }
}

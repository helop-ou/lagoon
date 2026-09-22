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

    typealias Negotiation = @MainActor (String, JellyfinClient) async throws -> PreparedPlayback?

    private let negotiate: Negotiation
    private var staging = Staging.none
    private var generation = 0
    private var preparationTask: Task<PreparedPlayback?, Never>?
    private var prepared: PreparedPlayback?
    private var itemID: String?
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

    func prepare(
        itemID: String,
        client: JellyfinClient,
        staging: Staging,
        warms: Bool
    ) {
        guard !hasPreparation else { return }
        generation &+= 1
        let generation = generation
        self.itemID = itemID
        self.staging = staging
        self.allowsWarming = warms
        let negotiate = negotiate
        preparationTask = Task { [weak self] in
            defer { self?.finishPreparation(generation: generation) }
            do {
                guard let result = try await negotiate(itemID, client),
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

    private static func negotiate(itemID: String, client: JellyfinClient) async throws -> PreparedPlayback? {
        let info = try await client.playbackInfo(itemId: itemID)
        guard !Task.isCancelled,
              info.errorCode == nil,
              let source = info.mediaSources.first else { return nil }
        // Disc images negotiate their own rung at playback start.
        let layout = PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType)
        guard !layout.isDisc else { return nil }
        let (url, method) = try client.streamURL(itemId: itemID, source: source)
        return PreparedPlayback(mediaID: itemID, info: info, source: source, streamURL: url, method: method)
    }
}

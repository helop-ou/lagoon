import Foundation
import LagoonEngine

/// Owns successor negotiation and hands the result to whatever will warm it.
/// The controller supplies only immutable inputs and a staging brief; network
/// work never retains the controller or the outgoing engine.
///
/// The warm-up itself belongs to the engine, which is where the cache and the
/// playback state that paces it live. What is left here is the half Jellyfin
/// owns: asking the server about the next episode, and making sure a late or
/// cancelled answer can never publish over its replacement.
@MainActor
final class PlaybackSuccessorPreparation {
    struct PreparedPlayback {
        let mediaID: String
        let info: PlaybackInfoResponse
        let source: MediaSource
        let streamURL: URL
        let method: PlayMethod
    }

    /// What to do with a negotiated successor. Injected so the preparation's
    /// generation rules can be tested without an engine.
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
                // Read the flag now rather than capturing it: a handoff that
                // began while the server was answering has already given up
                // its warm-up, and must not have one started behind it.
                self.staging.stage(result, self.allowsWarming)
                self.prepared = result
                return result
            } catch {
                return nil
            }
        }
    }

    /// A ready result remains usable after its task has finished. If the
    /// negotiation is still running, let it finish but stop or skip the
    /// optional warm-up: accepting Up Next must not wait out its pacing.
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

    /// Discard synchronously before a replacement can stage its scope.
    /// Cancelled work may finish later, including for the same item ID; its
    /// generation must never clear the new task or remove the new scope.
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
        // Disc images cannot use this warm-up; they negotiate their own
        // delivery rung when playback starts.
        let layout = PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType)
        guard !layout.isDisc else { return nil }
        let (url, method) = try client.streamURL(itemId: itemID, source: source)
        return PreparedPlayback(mediaID: itemID, info: info, source: source, streamURL: url, method: method)
    }
}

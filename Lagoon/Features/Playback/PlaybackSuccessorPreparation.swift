import Foundation

/// Owns successor negotiation and its bounded byte warm-up. The controller
/// supplies only immutable inputs and weak engine snapshots; network work
/// never retains the controller or the outgoing engine.
@MainActor
final class PlaybackSuccessorPreparation {
    struct PreparedPlayback {
        let mediaID: String
        let info: PlaybackInfoResponse
        let source: MediaSource
        let streamURL: URL
        let method: PlayMethod
    }

    struct PlaybackState {
        let isBuffering: Bool
        let stallCount: Int
        let isPaused: Bool
    }

    typealias StateProvider = @MainActor () -> PlaybackState?
    typealias Negotiation = @MainActor (String, JellyfinClient) async throws -> PreparedPlayback?
    typealias Warming = @MainActor (PlaybackCacheSession?, StateProvider) async -> Void

    private let negotiate: Negotiation
    private let warm: Warming
    private var generation = 0
    private var preparationTask: Task<PreparedPlayback?, Never>?
    private var warmTask: Task<Void, Never>?
    private var prepared: PreparedPlayback?
    private var cache: PlaybackCacheCoordinator?
    private var itemID: String?
    private var allowsWarming = false

    var isPreparing: Bool { preparationTask != nil }
    var hasPreparation: Bool { isPreparing || prepared != nil }

    init(
        negotiate: @escaping Negotiation = PlaybackSuccessorPreparation.negotiate,
        warm: @escaping Warming = PlaybackSuccessorPreparation.warm
    ) {
        self.negotiate = negotiate
        self.warm = warm
    }

    isolated deinit {
        preparationTask?.cancel()
        warmTask?.cancel()
        if let itemID { cache?.discardNext(itemID: itemID) }
    }

    func prepare(
        itemID: String,
        client: JellyfinClient,
        cache: PlaybackCacheCoordinator,
        allowsWarming: Bool,
        playbackState: @escaping StateProvider
    ) {
        guard !hasPreparation else { return }
        generation &+= 1
        let generation = generation
        self.itemID = itemID
        self.cache = cache
        self.allowsWarming = allowsWarming
        let negotiate = negotiate
        preparationTask = Task { [weak self] in
            defer { self?.finishPreparation(generation: generation) }
            do {
                guard let result = try await negotiate(itemID, client),
                      !Task.isCancelled,
                      self?.generation == generation else { return nil }
                let scope = cache.stageNext(
                    itemID: itemID,
                    url: result.streamURL,
                    method: result.method,
                    expectedLength: result.source.size,
                    authorization: client.mediaRequestAuthorization()
                )
                let warm = self?.startWarming(
                    scope,
                    playbackState: playbackState,
                    generation: generation
                )
                await warm?.value
                guard !Task.isCancelled,
                      self?.generation == generation else { return nil }
                self?.prepared = result
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
        warmTask?.cancel()
        let result: PreparedPlayback?
        if let prepared {
            result = prepared
        } else {
            result = await preparationTask?.value
        }
        guard self.generation == generation, !Task.isCancelled else { return nil }
        preparationTask = nil
        warmTask = nil
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
        warmTask?.cancel()
        warmTask = nil
        prepared = nil
        allowsWarming = false
        if let itemID { cache?.discardNext(itemID: itemID) }
        itemID = nil
        cache = nil
    }

    private func finishPreparation(generation: Int) {
        guard self.generation == generation else { return }
        preparationTask = nil
        warmTask = nil
    }

    private func startWarming(
        _ scope: PlaybackCacheSession?,
        playbackState: @escaping StateProvider,
        generation: Int
    ) -> Task<Void, Never>? {
        guard self.generation == generation, allowsWarming else { return nil }
        let warm = warm
        let task = Task { await warm(scope, playbackState) }
        warmTask = task
        return task
    }

    private static func negotiate(itemID: String, client: JellyfinClient) async throws -> PreparedPlayback? {
        let info = try await client.playbackInfo(itemId: itemID)
        guard !Task.isCancelled,
              info.errorCode == nil,
              let source = info.mediaSources.first else { return nil }
        // Disc images cannot use this warm-up; they negotiate their own
        // delivery rung when playback starts (HEL-133).
        let layout = PlaybackSourceLayout(videoType: source.videoType, isoType: source.isoType)
        guard !layout.isDisc else { return nil }
        let (url, method) = try client.streamURL(itemId: itemID, source: source)
        return PreparedPlayback(mediaID: itemID, info: info, source: source, streamURL: url, method: method)
    }

    /// Cooperative 1 MiB requests (the cache session's request size), up to
    /// eight MiB, with the same stall backoff and link-time pacing as before.
    /// Snapshots avoid holding an engine across network requests or sleeps.
    private static func warm(_ session: PlaybackCacheSession?, playbackState: StateProvider) async {
        guard let session, session.directScope != nil else { return }
        let startingBytes = session.metrics.contiguousCachedBytes
        var observedStalls = playbackState()?.stallCount ?? 0
        while !Task.isCancelled,
              session.metrics.contiguousCachedBytes - startingBytes < 8 * 1_024 * 1_024 {
            guard let state = playbackState() else { return }
            if state.isBuffering || state.stallCount > observedStalls {
                observedStalls = state.stallCount
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                continue
            }
            // A failed or exhausted warm-up chunk ends the warm-up: the
            // successor's own fill loop takes over once it starts, and this
            // one must never hold the link during the handoff.
            guard case .fetched(_, let requestSeconds) = await session.prefetchNextChunk() else { return }
            guard !Task.isCancelled, let state = playbackState() else { return }
            if !state.isPaused {
                let measured = max(requestSeconds, PlaybackFillPolicy.minimumMeasuredRequestSeconds)
                do {
                    try await Task.sleep(for: .seconds(min(
                        measured * PlaybackFillPolicy.relaxedPacingMultiplier,
                        PlaybackFillPolicy.relaxedPacingCapSeconds
                    )))
                } catch {
                    return
                }
            }
        }
    }
}

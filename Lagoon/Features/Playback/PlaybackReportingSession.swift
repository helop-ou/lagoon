import Foundation
import OSLog

private let reportLog = Logger(subsystem: "ee.helop.lagoon", category: "playback-reports")

/// Owns one server-side playback session. Its final report outlives local
/// teardown without retaining the controller, engine or a successor session.
@MainActor
final class PlaybackReportingSession {
    struct Progress {
        let seconds: Double
        let isPaused: Bool
    }

    private let client: JellyfinClient
    private let itemID: String
    private let mediaSourceID: String
    private let playSessionID: String?
    private let method: PlayMethod
    private let signpostID: OSSignpostID
    private let ledgerSession: UUID
    private var progressTask: Task<Void, Never>?
    private(set) var isActive = true

    init(
        client: JellyfinClient,
        itemID: String,
        mediaSourceID: String,
        playSessionID: String?,
        method: PlayMethod,
        signpostID: OSSignpostID
    ) {
        self.client = client
        self.itemID = itemID
        self.mediaSourceID = mediaSourceID
        self.playSessionID = playSessionID
        self.method = method
        self.signpostID = signpostID
        ledgerSession = client.playbackReports.open()
    }

    deinit {
        progressTask?.cancel()
    }

    func reportStart(at seconds: Double) async throws {
        try Task.checkCancellation()
        guard isActive else { throw CancellationError() }
        try await client.reportPlaybackStart(.init(
            itemId: itemID,
            mediaSourceId: mediaSourceID,
            playSessionId: playSessionID,
            positionTicks: Ticks.ticks(seconds),
            playMethod: method.rawValue,
            canSeek: true
        ))
    }

    /// Read a value snapshot immediately before reporting. Neither the loop
    /// nor a suspended network request needs to retain a player engine.
    func startProgress(
        snapshot: @escaping @MainActor () -> Progress?,
        didReport: @escaping @MainActor () -> Void
    ) {
        cancelProgress()
        guard isActive else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard let self, self.isActive, let progress = snapshot() else { return }
                let memory = MemorySnapshot.current()
                os_signpost(
                    .event,
                    log: PlaybackPerformance.log,
                    name: "Playback Memory",
                    signpostID: self.signpostID,
                    "footprintMB=%{public}.1f availableMB=%{public}.1f position=%{public}.3f",
                    memory.footprintMB,
                    memory.availableMB,
                    progress.seconds
                )
                try? await self.client.reportPlaybackProgress(.init(
                    itemId: self.itemID,
                    mediaSourceId: self.mediaSourceID,
                    playSessionId: self.playSessionID,
                    positionTicks: Ticks.ticks(progress.seconds),
                    isPaused: progress.isPaused,
                    playMethod: self.method.rawValue
                ))
                guard !Task.isCancelled, self.isActive else { return }
                didReport()
            }
        }
    }

    func cancelProgress() {
        progressTask?.cancel()
        progressTask = nil
    }

    /// Claims the stop report synchronously and returns independent network
    /// work. Call after local resource teardown; dismissal never awaits it.
    func stop(at seconds: Double) -> Task<Void, Never>? {
        cancelProgress()
        guard isActive else { return nil }
        isActive = false
        let client = client
        let itemID = itemID
        let mediaSourceID = mediaSourceID
        let playSessionID = playSessionID
        let signpostID = signpostID
        let ledgerSession = ledgerSession
        return Task {
            os_signpost(
                .begin, log: PlaybackPerformance.log,
                name: "Playback Stopped Report", signpostID: signpostID
            )
            do {
                try await client.reportPlaybackStopped(.init(
                    itemId: itemID,
                    mediaSourceId: mediaSourceID,
                    playSessionId: playSessionID,
                    positionTicks: Ticks.ticks(seconds)
                ))
                reportLog.notice("stopped at \(seconds, format: .fixed(precision: 1)) s reported")
            } catch {
                reportLog.error("stopped report failed: \(error.localizedDescription, privacy: .public)")
            }
            os_signpost(
                .end, log: PlaybackPerformance.log,
                name: "Playback Stopped Report", signpostID: signpostID
            )
            client.playbackReports.close(ledgerSession)
        }
    }
}

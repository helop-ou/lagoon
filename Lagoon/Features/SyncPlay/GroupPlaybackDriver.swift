import Foundation
import LagoonEngine

/// The playback side of a SyncPlay group; `SyncPlayStore` is membership.
///
/// Holds the controller **weakly** and the engine not at all. Transport goes
/// through `PlaybackController`'s group entry points, so a handoff or
/// fallback carries the group onto a successor engine.
///
/// - **Down**: a server command becomes a scheduled transport call, and
///   readiness is reported back.
/// - **Up**: the viewer's play, pause, seek and skip become group requests
///   and do nothing locally. The server's echo moves this player.
@MainActor
final class GroupPlaybackDriver: GroupTransportRequests {
    /// Seconds off target before a group start re-seeks. Below it the start
    /// anchor absorbs the difference; a seek would re-prime for nothing.
    static let resyncThreshold = 0.5
    /// Same at a pause, which has no anchor. 0.1 s is two to three frames.
    static let pauseThreshold = 0.1
    /// "Correct sync drift" in Settings, on by default. Off, drift is still
    /// measured and shown in the HUD.
    nonisolated static let correctionDefaultsKey = "syncplay.correction"

    /// Milliseconds, or nil when there is nothing to measure.
    var onDrift: ((Int?) -> Void)?
    /// Read from the store, not copied, so a queue update cannot leave two answers.
    var currentPlaylistItemId: (() -> String?)?
    var onPlayerClosed: (() -> Void)?
    var hudLines: (() -> [String])?
    var onRequestFailure: (() -> Void)?

    private let client: JellyfinClient
    private let clock: ServerClock
    private weak var controller: PlaybackController?

    /// The drift loop measures against this.
    private var command: SyncPlayCommand?
    private var scheduledCommand: Task<Void, Never>?
    /// In order: an unpause that overtakes a seek starts the group at the
    /// position the viewer just left.
    private let requests = SyncPlayRequestQueue()
    private var driftLoop: Task<Void, Never>?
    private var correctionHold: Task<Void, Never>?
    private var isCorrecting = false
    /// Last state sent; re-sending it only adds group latency.
    private var reportedReady: Bool?

    init(client: JellyfinClient, clock: ServerClock) {
        self.client = client
        self.clock = clock
    }

    var hasController: Bool { controller != nil }

    // MARK: - The player

    /// Reports Buffering at once, so the group waits for this member.
    func attach(_ controller: PlaybackController) {
        guard self.controller !== controller else { return }
        detachHooks()
        self.controller = controller
        controller.groupTransport = self
        controller.onEngineReady = { [weak self] in self?.engineBecameReady() }
        controller.onBufferingChanged = { [weak self] buffering in
            self?.engineBufferingChanged(buffering)
        }
        controller.onClosed = { [weak self] in self?.playerClosed() }
        controller.groupHUDLines = { [weak self] in self?.hudLines?() ?? [] }
        reportedReady = nil
        report(ready: false)
    }

    /// A new item while the player is open: stop-then-start like an episode
    /// handoff, so no second player is presented.
    func restart(media: MediaItem, positionSeconds: Double) async {
        guard let controller else { return }
        cancelTransport()
        reportedReady = nil
        report(ready: false, position: positionSeconds)
        await controller.startGroupItem(media, startPosition: positionSeconds)
    }

    func detach() {
        cancelTransport()
        controller?.setCorrectionRate(1)
        detachHooks()
        controller = nil
        onDrift?(nil)
    }

    private func detachHooks() {
        guard let controller else { return }
        controller.groupTransport = nil
        controller.onEngineReady = nil
        controller.onBufferingChanged = nil
        controller.onClosed = nil
        controller.groupHUDLines = nil
    }

    private func cancelTransport() {
        requests.cancel()
        scheduledCommand?.cancel()
        scheduledCommand = nil
        driftLoop?.cancel()
        driftLoop = nil
        correctionHold?.cancel()
        correctionHold = nil
        isCorrecting = false
        command = nil
        onDrift?(nil)
    }

    /// The store then sets ignore-wait so a closed player doesn't hold the
    /// group up until `rejoinPlayback()`.
    private func playerClosed() {
        detach()
        onPlayerClosed?()
    }

    // MARK: - Commands from the group

    func perform(_ command: SyncPlayCommand) {
        guard let when = command.whenSeconds else { return }
        let leadMilliseconds = Int(((when - clock.serverSeconds()) * 1_000).rounded())
        Diagnostics.record(.syncPlayCommand, [
            "command": .string(command.command.rawValue.lowercased()),
            "leadMs": .int(leadMilliseconds),
        ])
        scheduledCommand?.cancel()
        scheduledCommand = nil
        self.command = command
        switch command.command {
        case .unpause:
            unpause(command, at: when)
        case .pause:
            pause(command, at: when)
        case .seek:
            seek(to: command.positionSeconds)
        case .stop:
            closePlayer()
        case .unknown:
            break
        }
    }

    /// A group start names a future instant for every member to present
    /// `positionTicks` at. Nothing waits: seek first, then
    /// `playGroup(atHostTime:)` at once. The engine anchors on the instant
    /// when the first frame is ready; a seek issued *after* the start call
    /// drops it. Keep this order.
    private func unpause(_ command: SyncPlayCommand, at when: Double) {
        guard let controller else { return }
        restoreRate()
        // A past instant means the group is already running: the server
        // re-sends its last Unpause, with the start position, to a member
        // that turned Ready mid-play. Target where the group is now.
        let now = clock.serverSeconds()
        let target = when > now
            ? command.positionSeconds
            : SyncCorrectionPolicy.expectedPosition(
                commandPosition: command.positionSeconds,
                commandWhenServerSeconds: when,
                serverSeconds: now
            )
        if abs(controller.clockPosition - target) > Self.resyncThreshold {
            controller.seekGroup(to: target)
        }
        controller.playGroup(atHostTime: clock.hostTime(forServer: when))
        beginDriftLoop()
    }

    /// A pause has no anchor, so it sleeps until the instant.
    private func pause(_ command: SyncPlayCommand, at when: Double) {
        stopDriftLoop()
        let delay = SyncPlayCommandSchedule.delay(
            whenServerSeconds: when,
            clockOffset: clock.offset ?? 0,
            nowSeconds: Date().timeIntervalSince1970
        )
        scheduledCommand = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard !Task.isCancelled, let self, let controller = self.controller else { return }
            self.restoreRate()
            controller.pauseGroup()
            if abs(controller.clockPosition - command.positionSeconds) > Self.pauseThreshold {
                controller.seekGroup(to: command.positionSeconds)
            }
        }
    }

    private func seek(to seconds: Double) {
        guard let controller else { return }
        stopDriftLoop()
        restoreRate()
        controller.seekGroup(to: seconds)
        report(ready: false, position: seconds)
    }

    /// Stop closes the player but keeps the membership.
    func closePlayer() {
        controller?.close()
    }

    // MARK: - Readiness

    private func engineBecameReady() {
        report(ready: true)
    }

    private func engineBufferingChanged(_ buffering: Bool) {
        report(ready: !buffering)
    }

    /// `position` overrides the controller's while the player is missing or
    /// restarting.
    private func report(ready: Bool, position: Double? = nil) {
        guard let playlistItemId = currentPlaylistItemId?(), !playlistItemId.isEmpty else { return }
        if reportedReady == ready { return }
        reportedReady = ready
        enqueue(retryDelay: .seconds(1)) { [weak self] client in
            guard let self,
                  self.currentPlaylistItemId?() == playlistItemId,
                  self.reportedReady == ready else { return }
            // Built per attempt so a retry sends a fresh timestamp.
            let report = SyncPlayReadinessReport(
                when: JellyfinTimestamp.string(self.clock.serverSeconds()),
                positionTicks: Ticks.ticks(position ?? self.controller?.clockPosition ?? 0),
                isPlaying: self.controller?.isClockRunning ?? false,
                playlistItemId: playlistItemId
            )
            if ready {
                try await client.syncPlayReportReady(report)
            } else {
                try await client.syncPlayReportBuffering(report)
            }
        }
    }

    /// Buffering before the player opens, so the group waits from the queue update.
    func reportLoading(positionSeconds: Double) {
        reportedReady = nil
        report(ready: false, position: positionSeconds)
    }

    // MARK: - Drift

    private func beginDriftLoop() {
        driftLoop?.cancel()
        driftLoop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: SyncCorrectionPolicy.interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.evaluateDrift()
            }
        }
    }

    private func stopDriftLoop() {
        driftLoop?.cancel()
        driftLoop = nil
        onDrift?(nil)
    }

    private func evaluateDrift() {
        guard let controller,
              let command, command.command == .unpause,
              let when = command.whenSeconds else {
            onDrift?(nil)
            return
        }
        let now = clock.serverSeconds()
        // Measure only a running clock after the anchor settles; a
        // buffering member is stalled, not drifting.
        guard now > when + SyncCorrectionPolicy.settleSeconds,
              controller.isClockRunning else { return }
        let expected = SyncCorrectionPolicy.expectedPosition(
            commandPosition: command.positionSeconds,
            commandWhenServerSeconds: when,
            serverSeconds: now
        )
        let diff = expected - controller.clockPosition
        guard diff.isFinite else { return }
        let milliseconds = Int((diff * 1_000).rounded())
        onDrift?(milliseconds)
        guard Self.isCorrectionEnabled else { return }
        switch SyncCorrectionPolicy.decision(diff: diff) {
        case .none:
            restoreRate()
        case .rate(let multiplier, let hold):
            record(drift: milliseconds, correction: "rate")
            isCorrecting = true
            controller.setCorrectionRate(multiplier)
            correctionHold?.cancel()
            correctionHold = Task { [weak self] in
                do { try await Task.sleep(for: hold) } catch { return }
                guard !Task.isCancelled else { return }
                self?.restoreRate()
            }
        case .seek:
            record(drift: milliseconds, correction: "seek")
            restoreRate()
            controller.seekGroup(to: expected)
            report(ready: false, position: expected)
        }
    }

    private func restoreRate() {
        correctionHold?.cancel()
        correctionHold = nil
        guard isCorrecting else { return }
        isCorrecting = false
        controller?.setCorrectionRate(1)
    }

    private func record(drift milliseconds: Int, correction: String) {
        Diagnostics.record(.syncPlayDrift, [
            "driftMs": .int(milliseconds),
            "correction": .string(correction),
        ])
    }

    static var isCorrectionEnabled: Bool {
        UserDefaults.standard.object(forKey: correctionDefaultsKey) as? Bool ?? true
    }

    // MARK: - The viewer's transport (GroupTransportRequests)

    func requestPlay() {
        enqueue { try await $0.syncPlayUnpause() }
    }

    func requestPause() {
        enqueue { try await $0.syncPlayPause() }
    }

    func requestSeek(to seconds: Double, resume: Bool) {
        let ticks = Ticks.ticks(max(seconds, 0))
        enqueue { client in
            try await client.syncPlaySeek(positionTicks: ticks)
            // After the seek on the same chain, or the group starts where
            // the viewer no longer is.
            try Task.checkCancellation()
            if resume { try await client.syncPlayUnpause() }
        }
    }

    func requestNextItem() {
        guard let playlistItemId = currentPlaylistItemId?(), !playlistItemId.isEmpty else { return }
        enqueue { try await $0.syncPlayNextItem(playlistItemId: playlistItemId) }
    }

    // MARK: - Requests

    /// Serializes every request. A failure is tolerable: the next group
    /// command re-states the truth.
    private func enqueue(
        retryDelay: Duration? = nil,
        _ work: @escaping (JellyfinClient) async throws -> Void
    ) {
        let client = client
        requests.enqueue({ try await work(client) }, retryDelay: retryDelay, onFailure: { [weak self] in
            self?.reportedReady = nil
            self?.onRequestFailure?()
        })
    }
}

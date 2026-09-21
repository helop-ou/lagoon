import Foundation

/// Drives one player session from a SyncPlay group, and the group from that
/// player's viewer.
///
/// `SyncPlayStore` is membership — socket, group, queue, UI. This is the part
/// that touches playback. It holds the controller **weakly** and the engine
/// not at all; transport goes through `PlaybackController`'s group entry
/// points, so a handoff or fallback carries the group onto a successor engine
/// without this object knowing.
///
/// - **Down**: a server command becomes a scheduled transport call, and
///   readiness is reported back.
/// - **Up**: the viewer's play, pause, seek and skip become requests to the
///   group and do nothing locally. The server's echo moves this player.
@MainActor
final class GroupPlaybackDriver: GroupTransportRequests {
    /// Re-seek before a group start when the member is further than this
    /// from the position the group is starting at. Below it the start
    /// anchor alone is enough, and a seek would re-prime the pipeline for
    /// nothing.
    static let resyncThreshold = 0.5
    /// The same idea at a pause, where the member is stopping rather than
    /// starting and has no anchor to absorb the difference. A tenth of a
    /// second is two to three frames.
    static let pauseThreshold = 0.1
    /// Settings › Playback owns this as "Correct sync drift", on by
    /// default. Off, the drift is still measured and still reaches the
    /// HUD; nothing acts on it.
    nonisolated static let correctionDefaultsKey = "syncplay.correction"

    /// The drift measured at the last evaluation, in milliseconds, or nil
    /// when there is nothing to measure against.
    var onDrift: ((Int?) -> Void)?
    /// The group's handle for the item on screen. Read from the store
    /// rather than copied, so a queue update cannot leave two answers.
    var currentPlaylistItemId: (() -> String?)?
    /// The player session ended — the viewer left, or the group stopped.
    var onPlayerClosed: (() -> Void)?
    /// Group state for the playback HUD, supplied by the store.
    var hudLines: (() -> [String])?
    var onRequestFailure: (() -> Void)?

    private let client: JellyfinClient
    private let clock: ServerClock
    private weak var controller: PlaybackController?

    /// The command being acted on. Kept here as well as in the session
    /// because the drift loop measures against it every 1.5 s.
    private var command: SyncPlayCommand?
    private var scheduledCommand: Task<Void, Never>?
    /// Outgoing requests, one at a time and in order. A seek followed by
    /// an unpause must reach the server in that order or the group starts
    /// at the position the viewer just left.
    private let requests = SyncPlayRequestQueue()
    private var driftLoop: Task<Void, Never>?
    private var correctionHold: Task<Void, Never>?
    private var isCorrecting = false
    /// What the server was last told. Buffering and Ready are a state, not
    /// events: re-sending the one it already has only adds latency to the
    /// group.
    private var reportedReady: Bool?

    init(client: JellyfinClient, clock: ServerClock) {
        self.client = client
        self.clock = clock
    }

    var hasController: Bool { controller != nil }

    // MARK: - The player

    /// Called once the player exists. Reports Buffering at once: from here
    /// the group waits for this member.
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

    /// The group moved to another item while the player is open. The same
    /// stop-then-start an episode handoff does, so the player surface and
    /// the session survive it instead of a second player being presented.
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

    /// The viewer closed the player while still in the group. Staying in
    /// the group but holding it up would be the worst of both: ignore-wait
    /// takes this member out of the readiness accounting until it comes
    /// back through `SyncPlayStore.rejoinPlayback()`.
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

    /// A group start is not "play now": the server names an instant every
    /// member presents `positionTicks` at, far enough ahead (now + twice
    /// the slowest member's ping, at least half a second) for all of them
    /// to get there.
    ///
    /// Nothing waits here. `playGroup(atHostTime:)` is called immediately,
    /// even with the seek below still priming, because the engine
    /// remembers the instant and anchors on it when the first frame is
    /// ready — whereas a seek issued *after* the start call drops that
    /// instant. Order matters, and this is the order.
    private func unpause(_ command: SyncPlayCommand, at when: Double) {
        guard let controller else { return }
        restoreRate()
        // An instant already behind us is a group that is running, not
        // one about to start: the server re-states its last Unpause to a
        // member that reported Ready mid-play, with the position the group
        // started *from*. Comparing against that would seek this member
        // back to the start; the group is wherever that position has
        // advanced to since.
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

    /// A pause *is* waited for: there is no anchor to schedule against, so
    /// the member sleeps until the named instant arrives on its own clock.
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
            // Only when it matters: a seek re-primes the pipeline, and a
            // paused member three frames out is a member nobody can tell
            // is out.
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
        // The group is waiting on this member from here until the engine
        // anchors at the new position.
        report(ready: false, position: seconds)
    }

    /// Stop closes the player and keeps the membership: the group is still
    /// a group, it simply has nothing playing.
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

    /// Buffering and Ready are the same body; only the route differs.
    /// `position` overrides the controller's for the window where the
    /// player does not exist yet or is being restarted.
    private func report(ready: Bool, position: Double? = nil) {
        guard let playlistItemId = currentPlaylistItemId?(), !playlistItemId.isEmpty else { return }
        if reportedReady == ready { return }
        reportedReady = ready
        enqueue(retryDelay: .seconds(1)) { [weak self] client in
            guard let self,
                  self.currentPlaylistItemId?() == playlistItemId,
                  self.reportedReady == ready else { return }
            // Refresh the timestamp and clock position on the retry. A
            // newer queue/readiness state supersedes the failed report.
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

    /// Reports Buffering for an item whose player has not opened yet, so
    /// the group waits from the moment the queue update lands rather than
    /// from whenever this device finishes negotiating a stream.
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
        // Only a running clock can be measured, and only after the anchor
        // has settled. A buffering member is not drifting, it is stalled,
        // and the Buffering report is what the group needs from it.
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
            // Deliberately after the seek and on the same serialized
            // chain: the tvOS commit grammar is "land here *and* play on",
            // and an unpause that overtook the seek would start the group
            // where the viewer no longer is.
            try Task.checkCancellation()
            if resume { try await client.syncPlayUnpause() }
        }
    }

    func requestNextItem() {
        guard let playlistItemId = currentPlaylistItemId?(), !playlistItemId.isEmpty else { return }
        enqueue { try await $0.syncPlayNextItem(playlistItemId: playlistItemId) }
    }

    // MARK: - Requests

    /// Serializes everything this driver sends. Ordering is the whole
    /// point; a failure is not, since the group's own state is the truth
    /// and the next command re-states it.
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

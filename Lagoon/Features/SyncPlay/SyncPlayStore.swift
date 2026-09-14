import Foundation
import Observation
import UIKit

/// What the group wants played, for the presentation layer to turn into a
/// `PlayerItem` (HEL-172). The store never presents anything itself: the
/// player is owned by `MainTabView`, and this is the request it answers.
nonisolated struct SyncPlayPlayRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let media: MediaItem
    let startSeconds: Double
    let playlistItemId: String
}

/// Watch Together: membership in a SyncPlay group, and the bridge between
/// that group and this app's player (HEL-172).
///
/// Owned by `SessionStore` beside `seerr`, pointed at the active account by
/// `synchronizeAccountContext()`, and injected from `RootView` — plus the
/// iOS UIKit player host, which rebuilds the environment from scratch.
///
/// Membership is what lives here: the socket, the clock, the group, the
/// queue and what the viewer is told. Everything that touches playback is
/// in `GroupPlaybackDriver`, and everything that *decides* is in
/// `SyncPlayGroupSession`, which is pure and carries the tests.
///
/// The socket and the clock are opened on the first join and closed on the
/// last leave. Jellyfin's own clients keep a socket open for the whole
/// session; Lagoon does not need one until a group exists, and an account
/// that never uses Watch Together never opens one.
@Observable
final class SyncPlayStore {
    /// What this account may do with groups, as far as the server has been
    /// asked. `unknown` is "not asked yet, or could not be asked" — never a
    /// denial.
    enum Availability: Equatable, Sendable {
        case unknown
        case unavailable
        case joinOnly
        case createAndJoin

        var canJoin: Bool { self == .joinOnly || self == .createAndJoin }
        var canCreate: Bool { self == .createAndJoin }
    }

    /// A notice with an identity, so a future toast can animate one in and
    /// out without repeating itself.
    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let id: Int
        let notice: SyncPlayNotice
    }

    /// Enough to say what just happened, not a log.
    static let noticeCapacity = 8

    private(set) var availability: Availability = .unknown
    private(set) var groups: [SyncPlayGroup] = []
    private(set) var session = SyncPlayGroupSession()
    private(set) var notices: [Entry] = []
    /// How far this member is from where the group says it should be, in
    /// milliseconds; positive means behind. Nil when nothing is being
    /// measured. The playback HUD shows it.
    private(set) var driftMilliseconds: Int?
    /// Whether this member has taken itself out of the group's readiness
    /// accounting. Set when the player closes and cleared on the way back
    /// in; the player panel's Together tab offers it as a switch.
    private(set) var ignoresWait = false
    /// A player is attached to this group. Home offers a way back only
    /// while there is nothing on screen to come back to.
    private(set) var isPlayerOpen = false
    /// The group moved to an item and there is no player showing it.
    var pendingPlayRequest: SyncPlayPlayRequest?

    var isJoined: Bool { session.isJoined }
    /// The group is holding because some member is not ready — this one
    /// included. The player labels its spinner with it.
    var isWaitingForGroup: Bool { session.isJoined && session.state == .waiting }

    @ObservationIgnored private var client: JellyfinClient?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var socket: ServerSocket?
    @ObservationIgnored private var clock: ServerClock?
    @ObservationIgnored private var driver: GroupPlaybackDriver?
    @ObservationIgnored private var messages: Task<Void, Never>?
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var noticeCount = 0

    // MARK: - Account

    /// Called from `SessionStore.synchronizeAccountContext()`. A group
    /// belongs to the account that joined it, so switching accounts or
    /// signing out leaves it — silently, since nobody is watching a screen
    /// that is being torn down.
    func configure(client: JellyfinClient, accountID: String?) {
        guard self.accountID != accountID || self.client !== client else { return }
        let leaving = session.isJoined ? self.client : nil
        teardown()
        self.client = accountID == nil ? nil : client
        self.accountID = accountID
        availability = .unknown
        groups = []
        notices = []
        // Best effort, and deliberately not awaited: the account is
        // already gone as far as the rest of the app is concerned.
        if let leaving {
            Task { try? await leaving.syncPlayLeave() }
        }
    }

    // MARK: - Discovery

    func refreshAvailability() async {
        guard let client else {
            availability = .unavailable
            return
        }
        guard await client.isSyncPlayAvailable() else {
            availability = .unavailable
            return
        }
        switch await client.syncPlayAccess() {
        case .createAndJoinGroups: availability = .createAndJoin
        case .joinGroups: availability = .joinOnly
        case .none: availability = .unavailable
        case .unknown: availability = .unknown
        }
    }

    @discardableResult
    func refreshGroups() async -> [SyncPlayGroup] {
        guard let client, let listed = try? await client.syncPlayGroups() else { return groups }
        groups = listed
        return listed
    }

    // MARK: - Membership

    /// Creates a group and joins it in one step. The group's id is learned
    /// from the `GroupJoined` update the socket delivers, which is why the
    /// socket is opened first.
    func createGroup(named name: String) async {
        guard let client else { return }
        connect()
        await socketReady()
        try? await client.syncPlayCreateGroup(named: name)
        announceCapabilities()
    }

    /// Creates a group and puts one item in its queue: the whole of what a
    /// viewer standing on a detail page with nobody else's group to join
    /// is asking for.
    ///
    /// The two steps cannot be collapsed. `SyncPlay/New` answers 204 and
    /// the group's id arrives separately, over the socket, so there is
    /// nothing to set a queue on until that `GroupJoined` update lands.
    /// The queue update the server sends back is then what opens the
    /// player — here through `pendingPlayRequest`, and on every other
    /// member the same way.
    func startGroup(named name: String, playing item: MediaItem, startPositionTicks: Int64) async {
        guard let client else { return }
        await createGroup(named: name)
        guard await joinedGroupArrived() else { return }
        try? await client.syncPlaySetQueue(
            itemIds: [item.id],
            playingIndex: 0,
            startPositionTicks: startPositionTicks
        )
    }

    /// Puts an item in front of the whole group — "play this here". The
    /// same call `startGroup` finishes with, for a member that is already
    /// in a room.
    func play(_ item: MediaItem, startPositionTicks: Int64) async {
        guard let client, session.isJoined else { return }
        try? await client.syncPlaySetQueue(
            itemIds: [item.id],
            playingIndex: 0,
            startPositionTicks: startPositionTicks
        )
    }

    func join(_ group: SyncPlayGroup) async {
        await join(groupId: group.groupId)
    }

    func join(groupId: String) async {
        guard let client else { return }
        connect()
        await socketReady()
        do {
            try await client.syncPlayJoin(groupId: groupId)
            Diagnostics.record(.syncPlayJoin)
            announceCapabilities()
        } catch {
            // The `GroupDoesNotExist` update covers the case the server
            // knows about; a transport failure leaves the socket open and
            // the caller free to try again.
        }
    }

    /// Leaves the group and closes everything opened for it.
    func leave() async {
        let client = self.client
        let wasJoined = session.isJoined
        driver?.detach()
        session.reset()
        driftMilliseconds = nil
        ignoresWait = false
        isPlayerOpen = false
        pendingPlayRequest = nil
        disconnect()
        if wasJoined {
            Diagnostics.record(.syncPlayLeave)
            try? await client?.syncPlayLeave()
        }
    }

    /// Comes back to a group whose player was closed. `SetIgnoreWait(false)`
    /// puts this member back into the readiness accounting it took itself
    /// out of on the way out.
    func rejoinPlayback() async {
        guard let client, session.isJoined, let item = session.queue?.playingItem else { return }
        ignoresWait = false
        try? await client.syncPlaySetIgnoreWait(false)
        guard let media = try? await client.item(id: item.itemId) else { return }
        guard session.currentPlaylistItemId == item.playlistItemId else { return }
        // Where the group is now, not where the queue or the last command
        // started: the others have been watching, and opening behind them
        // makes the server correct this member — which holds the whole
        // group up while it does.
        let position = session.positionSeconds(
            atServerSeconds: clock?.serverSeconds() ?? Date().timeIntervalSince1970
        )
        pendingPlayRequest = SyncPlayPlayRequest(
            media: media,
            startSeconds: position,
            playlistItemId: item.playlistItemId
        )
    }

    // MARK: - Playback

    /// Called by `VideoPlayerView` once its controller exists. Outside a
    /// group this does nothing at all, which is what keeps every ordinary
    /// playback session exactly as it was.
    func attach(_ controller: PlaybackController) {
        guard session.isJoined, let driver else { return }
        driver.attach(controller)
        isPlayerOpen = true
    }

    /// Opts this member out of holding the group up, or back in. The
    /// player's Together tab is bound to it; the driver sets the same flag
    /// on its own when the player closes.
    func setIgnoreWait(_ ignore: Bool) async {
        guard let client, session.isJoined else { return }
        ignoresWait = ignore
        try? await client.syncPlaySetIgnoreWait(ignore)
    }

    /// The HUD's `Sync:` line (`-debug.playbackHUD`), assembled here
    /// because this is the object that knows the group, the last command
    /// and the drift.
    var hudLines: [String] {
        guard let group = session.group else { return [] }
        var line = "Sync:    \(session.state.rawValue.lowercased()) · \(group.participants.count) member"
        if group.participants.count != 1 { line += "s" }
        if let command = session.lastCommand {
            line += " · \(command.command.rawValue.lowercased())"
        }
        if let driftMilliseconds {
            line += String(format: " · drift %+d ms", driftMilliseconds)
        }
        return [line]
    }

    // MARK: - The socket

    private func connect() {
        guard let client, socket == nil else { return }
        let clock = ServerClock(client: client)
        clock.onSample = { [weak self] milliseconds in
            guard let self, let client = self.client, self.session.isJoined else { return }
            Task { try? await client.syncPlayPing(milliseconds: Int64(milliseconds)) }
        }
        clock.start()
        self.clock = clock

        let driver = GroupPlaybackDriver(client: client, clock: clock)
        driver.onDrift = { [weak self] milliseconds in self?.driftMilliseconds = milliseconds }
        driver.currentPlaylistItemId = { [weak self] in self?.session.currentPlaylistItemId }
        driver.hudLines = { [weak self] in self?.hudLines ?? [] }
        driver.onPlayerClosed = { [weak self] in
            guard let self else { return }
            pendingPlayRequest = nil
            isPlayerOpen = false
            // The driver posts `SetIgnoreWait(true)` as it lets go, so the
            // switch in the Together tab says what the server was told.
            ignoresWait = true
        }
        self.driver = driver

        let socket = ServerSocket(client: client)
        self.socket = socket
        let stream = socket.messages
        socket.connect()
        messages = Task { [weak self] in
            for await message in stream {
                guard let self else { return }
                self.handle(message)
            }
        }
        // The estimate is stale after a spell in the background, and a
        // group start instant is only as good as the offset it is turned
        // into. tvOS has the same notification and the same problem.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock?.forceUpdate() }
        }
    }

    /// Waits for the socket to be carrying messages before asking to join.
    ///
    /// Not caution: the server announces a join over the socket at the
    /// instant it happens, and a handshake still in flight misses it.
    /// Measured on fixture 12.0.0 — joining ~50 ms after `connect()` lost
    /// both the `GroupJoined` and the `PlayQueue` update, and the member
    /// then sat in a group it never heard another word from. The socket
    /// counts as open once the server's first `ForceKeepAlive` lands,
    /// which is the same moment the session's connection is registered.
    /// Five seconds, then the join is attempted anyway: a group nobody can
    /// hear is still better than no attempt at all, and a reconnect will
    /// pick the next one up.
    private func socketReady() async {
        guard let socket else { return }
        let deadline = ContinuousClock.now + .seconds(5)
        while socket.state != .open, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }

    /// Waits for the `GroupJoined` update that carries the id of the group
    /// just created. The same five-second budget `socketReady()` allows,
    /// and for the same reason: past it, whatever went wrong is not going
    /// to be fixed by waiting longer.
    private func joinedGroupArrived() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !session.isJoined, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        return session.isJoined
    }

    private func disconnect() {
        messages?.cancel()
        messages = nil
        socket?.disconnect()
        socket = nil
        clock?.stop()
        clock = nil
        driver = nil
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
            self.foregroundObserver = nil
        }
    }

    private func teardown() {
        driver?.detach()
        disconnect()
        session.reset()
        driftMilliseconds = nil
        ignoresWait = false
        isPlayerOpen = false
        pendingPlayRequest = nil
    }

    private func handle(_ message: ServerSocketMessage) {
        switch message.messageType {
        case "SyncPlayGroupUpdate":
            guard let update = try? message.decodePayload(SyncPlayGroupUpdate.self) else { return }
            apply(update)
        case "SyncPlayCommand":
            guard let command = try? message.decodePayload(SyncPlayCommand.self),
                  session.accepts(command) else { return }
            session.record(command)
            driver?.perform(command)
        default:
            // Every other server message belongs to a feature that is not
            // this one.
            break
        }
    }

    private func apply(_ update: SyncPlayGroupUpdate) {
        for effect in session.apply(update) {
            switch effect {
            case .loadItem(let itemId, let playlistItemId, let positionSeconds):
                // Before the item is even resolved: the group waits for
                // this member from the moment it is told to play something,
                // not from whenever a stream finishes negotiating.
                driver?.reportLoading(positionSeconds: positionSeconds)
                Task { await load(itemId: itemId, playlistItemId: playlistItemId, at: positionSeconds) }
            case .left:
                driver?.detach()
                driftMilliseconds = nil
                ignoresWait = false
                isPlayerOpen = false
                pendingPlayRequest = nil
                disconnect()
            case .notice(let notice):
                post(notice)
            case .accessDenied:
                break
            }
        }
    }

    private func load(itemId: String, playlistItemId: String, at positionSeconds: Double) async {
        guard let client, let media = try? await client.item(id: itemId) else { return }
        // The queue can move again while the item is being fetched.
        guard session.currentPlaylistItemId == playlistItemId else { return }
        if let driver, driver.hasController {
            await driver.restart(media: media, positionSeconds: positionSeconds)
        } else {
            pendingPlayRequest = SyncPlayPlayRequest(
                media: media,
                startSeconds: positionSeconds,
                playlistItemId: playlistItemId
            )
        }
    }

    private func announceCapabilities() {
        guard let client else { return }
        // Not required for command delivery; it is what makes the session
        // show up in Jellyfin's dashboard as a controllable video client.
        Task { try? await client.reportCapabilities() }
    }

    private func post(_ notice: SyncPlayNotice) {
        noticeCount += 1
        notices.append(Entry(id: noticeCount, notice: notice))
        if notices.count > Self.noticeCapacity {
            notices.removeFirst(notices.count - Self.noticeCapacity)
        }
    }
}

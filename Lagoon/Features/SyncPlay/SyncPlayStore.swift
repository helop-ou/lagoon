import Foundation
import Observation
import UIKit

/// What the group wants played, for the presentation layer to turn into a
/// `PlayerItem`. The store never presents anything itself: the
/// player is owned by `MainTabView`, and this is the request it answers.
nonisolated struct SyncPlayPlayRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let media: MediaItem
    let startSeconds: Double
    let playlistItemId: String
}

/// Watch Together: membership in a SyncPlay group, and the bridge between it
/// and this app's player.
///
/// Owned by `SessionStore` beside `seerr`, pointed at the active account by
/// `synchronizeAccountContext()`, injected from `RootView` and from the iOS
/// UIKit player host, which rebuilds the environment from scratch.
///
/// Membership lives here: socket, clock, group, queue, what the viewer is
/// told. Playback is `GroupPlaybackDriver`; the decisions are
/// `SyncPlayGroupSession`, which is pure and carries the tests.
///
/// Socket and clock open on the first join and close on the last leave.
/// Jellyfin's own clients hold one for the whole session; an account that
/// never uses Watch Together never opens one.
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
    private(set) var errorMessage: String?
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
    @ObservationIgnored private var sourceSession: JellyfinClient.SessionIdentity?
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored private var socket: ServerSocket?
    @ObservationIgnored private var clock: ServerClock?
    @ObservationIgnored private var driver: GroupPlaybackDriver?
    @ObservationIgnored private var messages: Task<Void, Never>?
    @ObservationIgnored private var itemLoad: Task<Void, Never>?
    @ObservationIgnored private let membershipRequests = SyncPlayRequestQueue()
    @ObservationIgnored private var foregroundObserver: NSObjectProtocol?
    @ObservationIgnored private var noticeCount = 0

    // MARK: - Account

    /// Called from `SessionStore.synchronizeAccountContext()`. A group
    /// belongs to the account that joined it, so switching accounts or
    /// signing out leaves it — silently, since nobody is watching a screen
    /// that is being torn down.
    func configure(client: JellyfinClient, accountID: String?) {
        guard self.accountID != accountID || sourceSession != client.sessionIdentity else { return }
        contextGeneration &+= 1
        let leaving = session.isJoined ? self.client : nil
        teardown()
        // SessionStore reuses and reconfigures its client before notifying
        // us. Keep this account's credentials independent, including the
        // best-effort Leave sent after an account switch.
        self.client = accountID == nil ? nil : client.sessionSnapshot()
        sourceSession = client.sessionIdentity
        self.accountID = accountID
        availability = .unknown
        errorMessage = nil
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
        let generation = contextGeneration
        guard await client.isSyncPlayAvailable() else {
            guard !Task.isCancelled, generation == contextGeneration, self.client === client else { return }
            availability = .unavailable
            return
        }
        let access = await client.syncPlayAccess()
        guard !Task.isCancelled, generation == contextGeneration, self.client === client else { return }
        switch access {
        case .createAndJoinGroups: availability = .createAndJoin
        case .joinGroups: availability = .joinOnly
        case .none: availability = .unavailable
        case .unknown: availability = .unknown
        }
    }

    @discardableResult
    func refreshGroups() async -> [SyncPlayGroup] {
        guard let client else { return groups }
        let generation = contextGeneration
        guard let listed = try? await client.syncPlayGroups() else { return groups }
        guard !Task.isCancelled, generation == contextGeneration, self.client === client else { return groups }
        groups = listed
        return listed
    }

    // MARK: - Membership

    /// Creates a group and joins it in one step. The group's id is learned
    /// from the `GroupJoined` update the socket delivers, which is why the
    /// socket is opened first.
    @discardableResult
    func createGroup(named name: String) async -> Bool {
        guard let client else { return false }
        let generation = contextGeneration
        errorMessage = nil
        connect()
        guard await socketReady() else {
            guard isCurrent(generation, client: client) else { return false }
            return fail("Couldn't connect to the group. Try again.")
        }
        guard isCurrent(generation, client: client) else { return false }
        do {
            try await client.syncPlayCreateGroup(named: name)
            guard isCurrent(generation, client: client) else { return false }
            announceCapabilities()
            return true
        } catch {
            guard isCurrent(generation, client: client) else { return false }
            return fail("Couldn't create the group. Try again.")
        }
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
    @discardableResult
    func startGroup(named name: String, playing item: MediaItem, startPositionTicks: Int64) async -> Bool {
        guard let client else { return false }
        let generation = contextGeneration
        guard await createGroup(named: name), isCurrent(generation, client: client) else { return false }
        guard await joinedGroupArrived(), isCurrent(generation, client: client) else {
            guard isCurrent(generation, client: client) else { return false }
            return fail("The group didn't respond. Try again.")
        }
        return await play(item, startPositionTicks: startPositionTicks)
    }

    /// Puts an item in front of the whole group — "play this here". The
    /// same call `startGroup` finishes with, for a member that is already
    /// in a room.
    @discardableResult
    func play(_ item: MediaItem, startPositionTicks: Int64) async -> Bool {
        guard let client, session.isJoined else { return false }
        let generation = contextGeneration
        errorMessage = nil
        do {
            try await client.syncPlaySetQueue(
                itemIds: [item.id],
                playingIndex: 0,
                startPositionTicks: startPositionTicks
            )
            return isCurrent(generation, client: client)
        } catch {
            guard isCurrent(generation, client: client) else { return false }
            return fail("Couldn't start this title for the group. Try again.")
        }
    }

    @discardableResult
    func join(_ group: SyncPlayGroup) async -> Bool {
        await join(groupId: group.groupId)
    }

    @discardableResult
    func join(groupId: String) async -> Bool {
        guard let client else { return false }
        let generation = contextGeneration
        errorMessage = nil
        connect()
        guard await socketReady() else {
            guard isCurrent(generation, client: client) else { return false }
            return fail("Couldn't connect to the group. Try again.")
        }
        guard isCurrent(generation, client: client) else { return false }
        do {
            try await client.syncPlayJoin(groupId: groupId)
            guard isCurrent(generation, client: client) else { return false }
            Diagnostics.record(.syncPlayJoin)
            announceCapabilities()
            return true
        } catch {
            guard isCurrent(generation, client: client) else { return false }
            return fail("Couldn't join the group. It may have ended. Try again.")
        }
    }

    /// Leaves the group and closes everything opened for it.
    func leave() async {
        // Invalidate item loads, socket waits and capability posts already in
        // flight. Their responses belong to the old membership.
        contextGeneration &+= 1
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
        let generation = contextGeneration
        errorMessage = nil
        do {
            // Resolve the item before opting back into readiness accounting:
            // an unavailable title must not leave the whole room waiting.
            let media = try await client.item(id: item.itemId)
            guard isCurrent(generation, client: client),
                  session.currentPlaylistItemId == item.playlistItemId else { return }
            guard await setIgnoreWait(false) else { return }
            guard isCurrent(generation, client: client),
                  session.currentPlaylistItemId == item.playlistItemId else { return }
            ignoresWait = false
            let position = session.positionSeconds(
                atServerSeconds: clock?.serverSeconds() ?? Date().timeIntervalSince1970
            )
            pendingPlayRequest = SyncPlayPlayRequest(
                media: media,
                startSeconds: position,
                playlistItemId: item.playlistItemId
            )
        } catch {
            guard isCurrent(generation, client: client) else { return }
            _ = fail("Couldn't reopen the group's title. Try again.")
        }
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
    /// player's Together tab is bound to it; closing the player uses the
    /// same serialized request and acknowledgement path.
    @discardableResult
    func setIgnoreWait(_ ignore: Bool) async -> Bool {
        guard let client, session.isJoined else { return false }
        let generation = contextGeneration
        var succeeded = false
        let request = membershipRequests.enqueue({ [weak self] in
            guard let self, self.isCurrent(generation, client: client), self.session.isJoined else { return }
            try await client.syncPlaySetIgnoreWait(ignore)
            guard self.isCurrent(generation, client: client) else { return }
            // Publish only the acknowledged value; a refused toggle must
            // not say this member has opted out of waiting when it hasn't.
            self.ignoresWait = ignore
            succeeded = true
        }, onFailure: { [weak self] in
            guard let self, self.isCurrent(generation, client: client) else { return }
            self.post(.requestFailed)
            _ = self.fail("Couldn't change group waiting. Try again or leave the group.")
        })
        await withTaskCancellationHandler {
            await request.value
        } onCancel: {
            request.cancel()
        }
        return succeeded
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
        clock.onSample = { [weak self, weak clock] milliseconds in
            guard let self, self.clock === clock, self.session.isJoined else { return }
            Task { try? await client.syncPlayPing(milliseconds: Int64(milliseconds)) }
        }
        clock.start()
        self.clock = clock

        let driver = GroupPlaybackDriver(client: client, clock: clock)
        driver.onDrift = { [weak self] milliseconds in self?.driftMilliseconds = milliseconds }
        driver.currentPlaylistItemId = { [weak self] in self?.session.currentPlaylistItemId }
        driver.hudLines = { [weak self] in self?.hudLines ?? [] }
        driver.onRequestFailure = { [weak self] in self?.post(.requestFailed) }
        driver.onPlayerClosed = { [weak self] in
            guard let self else { return }
            pendingPlayRequest = nil
            isPlayerOpen = false
            let generation = contextGeneration
            Task { [weak self] in
                guard let self, generation == self.contextGeneration else { return }
                await self.setIgnoreWait(true)
            }
        }
        self.driver = driver

        let socket = ServerSocket(client: client)
        self.socket = socket
        let stream = socket.messages
        let generation = contextGeneration
        socket.connect()
        messages = Task { [weak self] in
            for await message in stream {
                guard !Task.isCancelled, let self,
                      generation == self.contextGeneration,
                      self.socket === socket else { return }
                self.receive(message)
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
    /// Measured on the fixture server, 12.0.0 — joining ~50 ms after `connect()` lost
    /// both the `GroupJoined` and the `PlayQueue` update, and the member
    /// then sat in a group it never heard another word from. The socket
    /// counts as open once the server's first `ForceKeepAlive` lands,
    /// which is the same moment the session's connection is registered.
    /// A failed handshake leaves the sheet open for retry; joining without
    /// receiving messages can lose the group's initial queue permanently.
    private func socketReady() async -> Bool {
        guard let socket else { return false }
        let deadline = ContinuousClock.now + .seconds(5)
        while socket.state != .open, self.socket === socket, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return !Task.isCancelled && self.socket === socket && socket.state == .open
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
        itemLoad?.cancel()
        itemLoad = nil
        membershipRequests.cancel()
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

    /// Inbound socket boundary, also exercised with recorded server messages.
    func receive(_ message: ServerSocketMessage) {
        switch message.messageType {
        case "SyncPlayGroupUpdate":
            guard let update = try? message.decodePayload(SyncPlayGroupUpdate.self) else { return }
            apply(update)
        case "SyncPlayCommand":
            guard let command = try? message.decodePayload(SyncPlayCommand.self),
                  command.whenSeconds != nil,
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
                let generation = contextGeneration
                let client = self.client
                let previousLoad = itemLoad
                previousLoad?.cancel()
                itemLoad = Task { [weak self] in
                    // A cancelled restart must retire before its successor
                    // enters PlaybackController's stop/start boundary.
                    await previousLoad?.value
                    guard !Task.isCancelled, let self else { return }
                    await self.load(
                        itemId: itemId,
                        playlistItemId: playlistItemId,
                        at: positionSeconds,
                        generation: generation,
                        client: client
                    )
                }
            case .left:
                contextGeneration &+= 1
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

    private func load(
        itemId: String,
        playlistItemId: String,
        at positionSeconds: Double,
        generation: Int,
        client: JellyfinClient?
    ) async {
        guard let client, isCurrent(generation, client: client) else { return }
        let media: MediaItem
        do {
            media = try await client.item(id: itemId)
        } catch {
            guard isCurrent(generation, client: client),
                  session.currentPlaylistItemId == playlistItemId else { return }
            // Buffering was already reported when the queue arrived. A
            // missing/unreachable item must release this member's wait and
            // offer a deliberate retry instead of stranding the room.
            pendingPlayRequest = nil
            driver?.closePlayer()
            _ = await setIgnoreWait(true)
            guard isCurrent(generation, client: client) else { return }
            _ = fail("Couldn't load the group's title. Use Rejoin to try again, or leave the group.")
            post(.requestFailed)
            return
        }
        // The queue or account can move again while the item is being fetched.
        guard !Task.isCancelled, generation == contextGeneration,
              self.client === client,
              session.currentPlaylistItemId == playlistItemId else { return }
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

    func clearError() {
        errorMessage = nil
    }

    private func fail(_ message: String.LocalizationValue) -> Bool {
        errorMessage = String(localized: message)
        return false
    }

    private func isCurrent(_ generation: Int, client: JellyfinClient) -> Bool {
        !Task.isCancelled && generation == contextGeneration && self.client === client
    }

    private func post(_ notice: SyncPlayNotice) {
        noticeCount += 1
        notices.append(Entry(id: noticeCount, notice: notice))
        if notices.count > Self.noticeCapacity {
            notices.removeFirst(notices.count - Self.noticeCapacity)
        }
    }
}

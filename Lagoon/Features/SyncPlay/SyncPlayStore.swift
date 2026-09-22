import Foundation
import Observation
import UIKit

/// What the group wants played. The store never presents; `MainTabView`
/// owns the player and answers this request.
nonisolated struct SyncPlayPlayRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let media: MediaItem
    let startSeconds: Double
    let playlistItemId: String
}

/// Watch Together: SyncPlay group membership (socket, clock, group, queue,
/// notices). Playback is `GroupPlaybackDriver`; decisions are the pure,
/// tested `SyncPlayGroupSession`.
///
/// Owned by `SessionStore`. The iOS UIKit player host rebuilds the
/// environment, so it injects this store too. Socket and clock open on
/// join and close on leave.
@Observable
final class SyncPlayStore {
    /// `unknown` means not asked or could not ask, never a denial.
    enum Availability: Equatable, Sendable {
        case unknown
        case unavailable
        case joinOnly
        case createAndJoin

        var canJoin: Bool { self == .joinOnly || self == .createAndJoin }
        var canCreate: Bool { self == .createAndJoin }
    }

    nonisolated struct Entry: Identifiable, Equatable, Sendable {
        let id: Int
        let notice: SyncPlayNotice
    }

    static let noticeCapacity = 8

    private(set) var availability: Availability = .unknown
    private(set) var errorMessage: String?
    private(set) var groups: [SyncPlayGroup] = []
    private(set) var session = SyncPlayGroupSession()
    private(set) var notices: [Entry] = []
    /// Positive means behind the group.
    private(set) var driftMilliseconds: Int?
    /// Out of the group's readiness accounting. Set when the player closes.
    private(set) var ignoresWait = false
    private(set) var isPlayerOpen = false
    /// The group moved to an item and no player is showing it.
    var pendingPlayRequest: SyncPlayPlayRequest?

    var isJoined: Bool { session.isJoined }
    /// Some member, possibly this one, is not ready.
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

    /// A group belongs to the account that joined it, so switching accounts
    /// or signing out leaves it silently.
    func configure(client: JellyfinClient, accountID: String?) {
        guard self.accountID != accountID || sourceSession != client.sessionIdentity else { return }
        contextGeneration &+= 1
        let leaving = session.isJoined ? self.client : nil
        teardown()
        // SessionStore reconfigures its shared client before calling this;
        // snapshot so this account's credentials, and the Leave, stay its own.
        self.client = accountID == nil ? nil : client.sessionSnapshot()
        sourceSession = client.sessionIdentity
        self.accountID = accountID
        availability = .unknown
        errorMessage = nil
        groups = []
        notices = []
        // Best effort, not awaited.
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

    /// The group id arrives in a `GroupJoined` socket update, so the socket
    /// opens first.
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

    /// Creates a group and queues one item. Two steps: `SyncPlay/New`
    /// answers 204 and the group id arrives later over the socket. The
    /// server's queue update then opens the player on every member.
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

    /// "Play this here" for the whole group.
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

    func leave() async {
        // Invalidates in-flight work from the old membership.
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

    /// Reopens the player for a group and rejoins its readiness accounting.
    func rejoinPlayback() async {
        guard let client, session.isJoined, let item = session.queue?.playingItem else { return }
        let generation = contextGeneration
        errorMessage = nil
        do {
            // Resolve first: an unavailable title must not leave the room waiting.
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

    /// A no-op outside a group, so ordinary playback is untouched.
    func attach(_ controller: PlaybackController) {
        guard session.isJoined, let driver else { return }
        driver.attach(controller)
        isPlayerOpen = true
    }

    /// Opts this member out of holding the group up, or back in.
    @discardableResult
    func setIgnoreWait(_ ignore: Bool) async -> Bool {
        guard let client, session.isJoined else { return false }
        let generation = contextGeneration
        var succeeded = false
        let request = membershipRequests.enqueue({ [weak self] in
            guard let self, self.isCurrent(generation, client: client), self.session.isJoined else { return }
            try await client.syncPlaySetIgnoreWait(ignore)
            guard self.isCurrent(generation, client: client) else { return }
            // Publish only the acknowledged value.
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

    /// The HUD's `Sync:` line (`-debug.playbackHUD`).
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
        // The clock offset goes stale in the background.
        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clock?.forceUpdate() }
        }
    }

    /// Join only once the socket is open: the server announces the join over
    /// the socket at once, and a handshake in flight misses `GroupJoined`
    /// and `PlayQueue` for good (joining ~50 ms after `connect()` did, on
    /// 12.0.0). Open means the first `ForceKeepAlive` has landed.
    private func socketReady() async -> Bool {
        guard let socket else { return false }
        let deadline = ContinuousClock.now + .seconds(5)
        while socket.state != .open, self.socket === socket, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return !Task.isCancelled && self.socket === socket && socket.state == .open
    }

    /// Waits for the `GroupJoined` update of a group just created.
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
            break
        }
    }

    private func apply(_ update: SyncPlayGroupUpdate) {
        for effect in session.apply(update) {
            switch effect {
            case .loadItem(let itemId, let playlistItemId, let positionSeconds):
                // Report loading before resolving, so the group waits from now.
                driver?.reportLoading(positionSeconds: positionSeconds)
                let generation = contextGeneration
                let client = self.client
                let previousLoad = itemLoad
                previousLoad?.cancel()
                itemLoad = Task { [weak self] in
                    // A cancelled restart must finish before its successor
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
            // Release this member's wait rather than strand the room.
            pendingPlayRequest = nil
            driver?.closePlayer()
            _ = await setIgnoreWait(true)
            guard isCurrent(generation, client: client) else { return }
            _ = fail("Couldn't load the group's title. Use Rejoin to try again, or leave the group.")
            post(.requestFailed)
            return
        }
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
        // Makes the session show as controllable in Jellyfin's dashboard.
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

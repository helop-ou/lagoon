import Foundation

// Watch Together: the group's state as this client understands it, and the
// rules for what to do about an update or a command (HEL-172).
//
// Everything here is pure. The socket, the clock, the player and the
// network live in `SyncPlayStore` and `GroupPlaybackDriver`; this file is
// the part that decides, and therefore the part that is tested. A rule
// that only exists inside an `async` method of a store is a rule nothing
// can pin down.

/// Something the group asked for that the session itself cannot do.
nonisolated enum SyncPlaySessionEffect: Equatable, Sendable {
    /// The group moved to an item: resolve it and open the player there,
    /// paused, at `positionSeconds`.
    case loadItem(itemId: String, playlistItemId: String, positionSeconds: Double)
    /// Membership is over, for the reason given.
    case left(reason: SyncPlayLeaveReason)
    /// Something worth telling the viewer once.
    case notice(SyncPlayNotice)
    /// The group is playing from a library this account cannot see.
    case accessDenied
}

nonisolated enum SyncPlayLeaveReason: Equatable, Sendable {
    /// The server confirmed this client left — its own request, or another
    /// session of the same user taking over.
    case leftGroup
    /// A request was refused because this client is not in a group.
    case notInGroup
    /// The group is gone.
    case groupDoesNotExist
}

/// A one-line event for the viewer. Carries display names, never ids, and
/// never reaches diagnostics — see `DiagnosticSchema`.
nonisolated enum SyncPlayNotice: Equatable, Sendable {
    case joined(group: String)
    case userJoined(String)
    case userLeft(String)
    case state(SyncPlayGroupState, reason: String)
    case left(SyncPlayLeaveReason)
    case accessDenied
    case requestFailed
}

/// The group as this client knows it, advanced only by what the server
/// says.
///
/// A value type on purpose: the store holds one, and every rule below can
/// be exercised by building a session and feeding it fixtures, with no
/// socket, no clock and no player.
nonisolated struct SyncPlayGroupSession: Equatable, Sendable {
    /// The reasons a queue update means "a different thing is playing
    /// now". `Queue`, `QueueNext`, `MoveItem`, `RepeatMode` and
    /// `ShuffleMode` rearrange what comes later and must not restart the
    /// item on screen. `RemoveItems` only counts when the removal took the
    /// playing item with it, which the identity comparison catches.
    static let loadingReasons: Set<SyncPlayQueueReason> = [
        .newPlaylist, .setCurrentItem, .nextItem, .previousItem, .removeItems,
    ]

    private(set) var group: SyncPlayGroup?
    private(set) var participants: [String] = []
    private(set) var state: SyncPlayGroupState = .idle
    private(set) var queue: SyncPlayQueueUpdate?
    /// The group's `LastUpdatedAt` when this client joined, on the server's
    /// clock. Commands emitted before it belong to a conversation this
    /// client was not part of; jellyfin-web drops them the same way.
    private(set) var joinedAtServerSeconds: Double?
    /// The last command this session accepted, which is what makes a
    /// re-sent command recognisable and what the drift correction measures
    /// against.
    private(set) var lastCommand: SyncPlayCommand?

    /// The `LastUpdate` of the newest queue update applied, so an older one
    /// arriving late cannot rewind the queue.
    private var lastQueueUpdateSeconds: Double?

    var isJoined: Bool { group != nil }
    var groupId: String? { group?.groupId }
    var groupName: String? { group?.groupName }
    var currentPlaylistItemId: String? { queue?.playingItem?.playlistItemId }
    var currentItemId: String? { queue?.playingItem?.itemId }
    /// Where the group's current item starts, which is where a member that
    /// opens the player later has to begin.
    var startSeconds: Double { Ticks.seconds(queue?.startPositionTicks ?? 0) }

    /// Where the group is *now*, as well as this session can tell: the
    /// last command's position, carried forward by the server time since
    /// its instant.
    ///
    /// Only an `Unpause` is carried forward — after a `Pause` or a `Seek`
    /// the group is sitting still at the position it named. A member
    /// coming back to a group that has been running for ten minutes would
    /// otherwise open where that command left it, and the server would
    /// have to drag it forward, holding everyone else up while it did
    /// (HEL-172).
    func positionSeconds(atServerSeconds now: Double) -> Double {
        guard let lastCommand else { return startSeconds }
        guard lastCommand.command == .unpause,
              let when = lastCommand.whenSeconds,
              now > when else { return lastCommand.positionSeconds }
        return SyncCorrectionPolicy.expectedPosition(
            commandPosition: lastCommand.positionSeconds,
            commandWhenServerSeconds: when,
            serverSeconds: now
        )
    }

    // MARK: - Updates

    mutating func apply(_ update: SyncPlayGroupUpdate) -> [SyncPlaySessionEffect] {
        if update.type == .groupJoined {
            guard let joined = update.group else { return [] }
            start(with: joined)
            return [.notice(.joined(group: joined.groupName))]
        }
        // An update names the group it is about. An empty id is accepted as
        // being about us: a refusal such as `NotInGroup` has no group to
        // name, and dropping it would leave the session pretending to be in
        // a group the server says it is not in.
        guard let group, update.groupId.isEmpty || update.concerns(groupId: group.groupId) else { return [] }

        switch update.type {
        case .userJoined:
            guard let name = update.text else { return [] }
            if !participants.contains(name) { participants.append(name) }
            return [.notice(.userJoined(name))]
        case .userLeft:
            guard let name = update.text else { return [] }
            participants.removeAll { $0 == name }
            return [.notice(.userLeft(name))]
        case .groupLeft:
            reset()
            return [.left(reason: .leftGroup), .notice(.left(.leftGroup))]
        case .notInGroup:
            reset()
            return [.left(reason: .notInGroup), .notice(.left(.notInGroup))]
        case .groupDoesNotExist:
            reset()
            return [.left(reason: .groupDoesNotExist), .notice(.left(.groupDoesNotExist))]
        case .libraryAccessDenied:
            return [.accessDenied, .notice(.accessDenied)]
        case .stateUpdate:
            guard let stateUpdate = update.stateUpdate, stateUpdate.state != state else { return [] }
            state = stateUpdate.state
            return [.notice(.state(stateUpdate.state, reason: stateUpdate.reason))]
        case .playQueue:
            return applyQueue(update.queueUpdate)
        case .groupJoined, .unknown:
            return []
        }
    }

    private mutating func start(with joined: SyncPlayGroup) {
        group = joined
        participants = joined.participants
        state = joined.state
        // A new membership starts with no queue and no command history,
        // even when the previous one had both.
        queue = nil
        lastQueueUpdateSeconds = nil
        lastCommand = nil
        joinedAtServerSeconds = JellyfinTimestamp.seconds(joined.lastUpdatedAt)
    }

    private mutating func applyQueue(_ update: SyncPlayQueueUpdate?) -> [SyncPlaySessionEffect] {
        guard let update else { return [] }
        let stamp = JellyfinTimestamp.seconds(update.lastUpdate)
        // Not newer than what is already applied: a duplicate or a
        // reordered delivery, and acting on it would restart the item.
        if let stamp, let applied = lastQueueUpdateSeconds, stamp <= applied { return [] }
        let previous = currentPlaylistItemId
        queue = update
        if let stamp { lastQueueUpdateSeconds = stamp }
        guard let playing = update.playingItem,
              playing.playlistItemId != previous,
              Self.loadingReasons.contains(update.reason) else { return [] }
        return [.loadItem(
            itemId: playing.itemId,
            playlistItemId: playing.playlistItemId,
            positionSeconds: Ticks.seconds(update.startPositionTicks)
        )]
    }

    // MARK: - Commands

    /// Whether this command is one to act on.
    ///
    /// The server broadcasts to everyone and repeats itself, so four
    /// separate things are refused here: a command for another group, one
    /// emitted before this client joined, one about an item that is not the
    /// one playing, and one this session has already taken — a `Seek`
    /// excepted, for the reason given below.
    func accepts(_ command: SyncPlayCommand) -> Bool {
        guard let group, command.command != .unknown else { return false }
        guard command.groupId.isEmpty
            || SyncPlayGroupIdentifier.matches(command.groupId, group.groupId) else { return false }
        // The all-zero playlist id on the `Stop` a freshly created group is
        // greeted with: there is nothing queued to stop.
        guard command.hasPlaylistItem else { return false }
        if let joinedAtServerSeconds,
           let emitted = JellyfinTimestamp.seconds(command.emittedAt),
           emitted < joinedAtServerSeconds {
            return false
        }
        // Stop is the exception: it ends whatever is on screen, including
        // an item the queue has already moved past.
        if command.command != .stop {
            guard let current = currentPlaylistItemId,
                  SyncPlayGroupIdentifier.matches(command.playlistItemId, current) else { return false }
        }
        // A re-sent `Seek` is the one command that is never a re-statement.
        // The server sends it to a single member whose `Ready` named a
        // position more than half a second from the group's — "got lost in
        // time, correcting" — and builds it out of the group's own state,
        // so it arrives byte-identical to the `Seek` this member has
        // already taken bar `EmittedAt`. Refusing it leaves the member
        // sitting where it is with nothing left to report, and the group
        // waits on it for ever (HEL-172).
        if command.command != .seek, let lastCommand, Self.isRepeat(of: lastCommand, command) {
            return false
        }
        return true
    }

    /// A re-send of the command already taken: the same instruction, for
    /// the same item, at the same instant. `EmittedAt` deliberately does
    /// not count — that is the field that differs between the original and
    /// the re-send.
    static func isRepeat(of previous: SyncPlayCommand, _ command: SyncPlayCommand) -> Bool {
        previous.command == command.command
            && previous.when == command.when
            && previous.positionTicks == command.positionTicks
            && SyncPlayGroupIdentifier.matches(previous.playlistItemId, command.playlistItemId)
    }

    /// Remembers an accepted command. Separate from `accepts` so the caller
    /// can decide a command is unusable for its own reasons — an
    /// unparseable `When`, say — without it becoming the one every later
    /// duplicate is compared against.
    mutating func record(_ command: SyncPlayCommand) {
        lastCommand = command
    }

    mutating func reset() {
        group = nil
        participants = []
        state = .idle
        queue = nil
        lastQueueUpdateSeconds = nil
        joinedAtServerSeconds = nil
        lastCommand = nil
    }
}

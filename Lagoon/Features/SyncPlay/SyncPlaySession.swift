import Foundation

// Watch Together's group state and rules, kept pure so they are tested.
// The socket, clock, player and network live in `SyncPlayStore` and
// `GroupPlaybackDriver`.

/// Something the group asked for that the session itself cannot do.
nonisolated enum SyncPlaySessionEffect: Equatable, Sendable {
    /// Resolve the item and open the player there, paused.
    case loadItem(itemId: String, playlistItemId: String, positionSeconds: Double)
    case left(reason: SyncPlayLeaveReason)
    case notice(SyncPlayNotice)
    /// The group plays from a library this account cannot see.
    case accessDenied
}

nonisolated enum SyncPlayLeaveReason: Equatable, Sendable {
    /// Its own request, or another session of the same user taking over.
    case leftGroup
    case notInGroup
    case groupDoesNotExist
}

/// Carries display names, never ids, and never reaches diagnostics; see
/// `DiagnosticSchema`.
nonisolated enum SyncPlayNotice: Equatable, Sendable {
    case joined(group: String)
    case userJoined(String)
    case userLeft(String)
    case state(SyncPlayGroupState, reason: String)
    case left(SyncPlayLeaveReason)
    case accessDenied
    case requestFailed
}

/// The group as this client knows it, advanced only by what the server says.
nonisolated struct SyncPlayGroupSession: Equatable, Sendable {
    /// Queue reasons that mean a different item is playing. The others only
    /// rearrange what comes later and must not restart the item on screen.
    /// `RemoveItems` counts only if the playing item changed.
    static let loadingReasons: Set<SyncPlayQueueReason> = [
        .newPlaylist, .setCurrentItem, .nextItem, .previousItem, .removeItems,
    ]

    private(set) var group: SyncPlayGroup?
    private(set) var participants: [String] = []
    private(set) var state: SyncPlayGroupState = .idle
    private(set) var queue: SyncPlayQueueUpdate?
    /// Server time of joining. Earlier commands are dropped, as jellyfin-web does.
    private(set) var joinedAtServerSeconds: Double?
    /// Recognises re-sent commands; drift correction measures against it.
    private(set) var lastCommand: SyncPlayCommand?

    /// So a late, older queue update cannot rewind the queue.
    private var lastQueueUpdateSeconds: Double?

    var isJoined: Bool { group != nil }
    var groupName: String? { group?.groupName }
    var currentPlaylistItemId: String? { queue?.playingItem?.playlistItemId }
    var startSeconds: Double { Ticks.seconds(queue?.startPositionTicks ?? 0) }

    /// Where the group is now: an `Unpause` position carried forward by
    /// elapsed server time. After `Pause` or `Seek` the group is still.
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
        // An empty group id is about us: a refusal like `NotInGroup` has no
        // group to name, and must not be dropped.
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
        queue = nil
        lastQueueUpdateSeconds = nil
        lastCommand = nil
        joinedAtServerSeconds = JellyfinTimestamp.seconds(joined.lastUpdatedAt)
    }

    private mutating func applyQueue(_ update: SyncPlayQueueUpdate?) -> [SyncPlaySessionEffect] {
        guard let update else { return [] }
        let stamp = JellyfinTimestamp.seconds(update.lastUpdate)
        // A duplicate or reordered delivery would restart the item.
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

    /// The server broadcasts and repeats itself, so this refuses commands
    /// for another group, from before joining, for another item, or
    /// already taken (except `Seek`).
    func accepts(_ command: SyncPlayCommand) -> Bool {
        guard let group, command.command != .unknown else { return false }
        guard command.groupId.isEmpty
            || SyncPlayGroupIdentifier.matches(command.groupId, group.groupId) else { return false }
        // A new group is greeted with a `Stop` for the all-zero playlist id.
        guard command.hasPlaylistItem else { return false }
        if let joinedAtServerSeconds,
           let emitted = JellyfinTimestamp.seconds(command.emittedAt),
           emitted < joinedAtServerSeconds {
            return false
        }
        // Stop ends whatever is on screen, even an item the queue moved past.
        if command.command != .stop {
            guard let current = currentPlaylistItemId,
                  SyncPlayGroupIdentifier.matches(command.playlistItemId, current) else { return false }
        }
        // A re-sent `Seek` is a correction: the server sends it to a member
        // whose `Ready` was over 0.5 s off, identical to the last `Seek` but
        // for `EmittedAt`. Refusing it leaves the group waiting for ever.
        if command.command != .seek, let lastCommand, Self.isRepeat(of: lastCommand, command) {
            return false
        }
        return true
    }

    /// Ignores `EmittedAt`, the one field a re-send changes.
    static func isRepeat(of previous: SyncPlayCommand, _ command: SyncPlayCommand) -> Bool {
        previous.command == command.command
            && previous.when == command.when
            && previous.positionTicks == command.positionTicks
            && SyncPlayGroupIdentifier.matches(previous.playlistItemId, command.playlistItemId)
    }

    /// Separate from `accepts` so a command the caller rejects (an
    /// unparseable `When`) never becomes the duplicate baseline.
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

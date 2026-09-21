import Foundation

// SyncPlay: shared playback across the devices in a group.
//
// The wire types live here rather than in JellyfinModels because only this
// feature and the socket read them. Two rules apply throughout:
//
// - Every server enumeration decodes with an `unknown` fallback. A group
//   state or a queue reason Lagoon has never heard of must not fail the
//   whole update: the rest of it still says what happened.
// - `When`, `EmittedAt` and `LastUpdate` stay `String`. They are wall-clock
//   instants on the *server's* clock and are converted only through
//   `JellyfinTimestamp`, paired with `ServerClock`'s offset.

// MARK: - Identifiers

/// Jellyfin spells the same group id two ways in the same session: the
/// `GroupId` fields and `SyncPlay/New` use undashed lowercase hex
/// (`ea9615382d214f9c9313c26fbd3bad89`), while the `GroupLeft` update's
/// payload is the dashed form of the same value. Measured on the fixture server, 12.0.0
/// on 2026-09-14. Compare through here, never with `==` on the raw strings.
nonisolated enum SyncPlayGroupIdentifier {
    static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func matches(_ one: String, _ other: String) -> Bool {
        normalized(one) == normalized(other)
    }

    /// Jellyfin's "no item" playlist id: an all-zero GUID, which arrives on
    /// the `Stop` command a freshly created group is greeted with.
    static func isEmptyIdentifier(_ id: String) -> Bool {
        let normalized = normalized(id)
        return normalized.isEmpty || normalized.allSatisfy { $0 == "0" }
    }
}

// MARK: - Group

nonisolated enum SyncPlayGroupState: String, Codable, Hashable, Sendable {
    case idle = "Idle"
    case waiting = "Waiting"
    case paused = "Paused"
    case playing = "Playing"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayGroupState(rawValue: raw) ?? .unknown
    }
}

/// `GroupInfoDto`: one group as `SyncPlay/List` and `GroupJoined` describe it.
nonisolated struct SyncPlayGroup: Decodable, Identifiable, Hashable, Sendable {
    let groupId: String
    let groupName: String
    let state: SyncPlayGroupState
    let participants: [String]
    /// Server wall clock; see the file header.
    let lastUpdatedAt: String

    var id: String { groupId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        groupId = try c.decode(String.self, forKey: "groupId")
        groupName = try c.decodeIfPresent(String.self, forKey: "groupName") ?? ""
        state = (try? c.decode(SyncPlayGroupState.self, forKey: "state")) ?? .unknown
        participants = (try? c.decodeIfPresent([String].self, forKey: "participants")) ?? []
        lastUpdatedAt = try c.decodeIfPresent(String.self, forKey: "lastUpdatedAt") ?? ""
    }
}

// MARK: - Commands

nonisolated enum SyncPlayCommandKind: String, Codable, Hashable, Sendable {
    case unpause = "Unpause"
    case pause = "Pause"
    case stop = "Stop"
    case seek = "Seek"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayCommandKind(rawValue: raw) ?? .unknown
    }
}

/// `SendCommand`: what the group wants every member to do, and when.
///
/// `when` is the whole point — the server names an instant on its own clock
/// and each client schedules against it, which is why it is not a delay and
/// cannot be acted on without `ServerClock`.
nonisolated struct SyncPlayCommand: Decodable, Hashable, Sendable {
    let groupId: String
    let playlistItemId: String
    /// Server wall clock: act at this instant.
    let when: String
    let positionTicks: Int64
    let command: SyncPlayCommandKind
    /// Server wall clock: when the server sent this.
    let emittedAt: String

    /// A new group is greeted with a `Stop` whose playlist item is the
    /// all-zero GUID and whose position is 0 — there is nothing queued yet.
    /// Verified on the fixture server, 12.0.0.
    var hasPlaylistItem: Bool { !SyncPlayGroupIdentifier.isEmptyIdentifier(playlistItemId) }

    var positionSeconds: Double { Ticks.seconds(positionTicks) }

    /// The instant to act on, in seconds since 1970 on the server's clock.
    var whenSeconds: Double? { JellyfinTimestamp.seconds(when) }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        groupId = try c.decodeIfPresent(String.self, forKey: "groupId") ?? ""
        playlistItemId = try c.decodeIfPresent(String.self, forKey: "playlistItemId") ?? ""
        when = try c.decodeIfPresent(String.self, forKey: "when") ?? ""
        positionTicks = try c.decodeIfPresent(Int64.self, forKey: "positionTicks") ?? 0
        command = (try? c.decode(SyncPlayCommandKind.self, forKey: "command")) ?? .unknown
        emittedAt = try c.decodeIfPresent(String.self, forKey: "emittedAt") ?? ""
    }
}

// MARK: - Play queue

nonisolated struct SyncPlayQueueItem: Decodable, Identifiable, Hashable, Sendable {
    let itemId: String
    /// The group's handle for this entry. Commands name it, not the item:
    /// the same title can sit in the queue twice.
    let playlistItemId: String

    var id: String { playlistItemId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        itemId = try c.decodeIfPresent(String.self, forKey: "itemId") ?? ""
        playlistItemId = try c.decodeIfPresent(String.self, forKey: "playlistItemId") ?? ""
    }
}

nonisolated enum SyncPlayQueueReason: String, Codable, Hashable, Sendable {
    case newPlaylist = "NewPlaylist"
    case setCurrentItem = "SetCurrentItem"
    case removeItems = "RemoveItems"
    case moveItem = "MoveItem"
    case queue = "Queue"
    case queueNext = "QueueNext"
    case nextItem = "NextItem"
    case previousItem = "PreviousItem"
    case repeatMode = "RepeatMode"
    case shuffleMode = "ShuffleMode"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayQueueReason(rawValue: raw) ?? .unknown
    }
}

/// `PlayQueueUpdate`: the group's queue, and where in it everyone is.
nonisolated struct SyncPlayQueueUpdate: Decodable, Hashable, Sendable {
    let reason: SyncPlayQueueReason
    /// Server wall clock: updates older than the one already applied are
    /// stale and must be dropped, which is what this is for.
    let lastUpdate: String
    let playlist: [SyncPlayQueueItem]
    let playingItemIndex: Int
    let startPositionTicks: Int64
    let isPlaying: Bool
    let shuffleMode: String
    let repeatMode: String

    var playingItem: SyncPlayQueueItem? {
        playlist.indices.contains(playingItemIndex) ? playlist[playingItemIndex] : nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        reason = (try? c.decode(SyncPlayQueueReason.self, forKey: "reason")) ?? .unknown
        lastUpdate = try c.decodeIfPresent(String.self, forKey: "lastUpdate") ?? ""
        playlist = (try? c.decodeIfPresent([SyncPlayQueueItem].self, forKey: "playlist")) ?? []
        playingItemIndex = try c.decodeIfPresent(Int.self, forKey: "playingItemIndex") ?? 0
        startPositionTicks = try c.decodeIfPresent(Int64.self, forKey: "startPositionTicks") ?? 0
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: "isPlaying") ?? false
        shuffleMode = try c.decodeIfPresent(String.self, forKey: "shuffleMode") ?? ""
        repeatMode = try c.decodeIfPresent(String.self, forKey: "repeatMode") ?? ""
    }
}

// MARK: - Group updates

nonisolated struct SyncPlayStateUpdate: Decodable, Hashable, Sendable {
    let state: SyncPlayGroupState
    /// The `PlaybackRequestType` that caused the transition — "Unpause",
    /// "Play", "Seek" and so on. A plain string: it is a label for the
    /// viewer and for logs, not something Lagoon branches on.
    let reason: String

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        state = (try? c.decode(SyncPlayGroupState.self, forKey: "state")) ?? .unknown
        reason = try c.decodeIfPresent(String.self, forKey: "reason") ?? ""
    }
}

nonisolated enum SyncPlayGroupUpdateType: String, Codable, Hashable, Sendable {
    case userJoined = "UserJoined"
    case userLeft = "UserLeft"
    case groupJoined = "GroupJoined"
    case groupLeft = "GroupLeft"
    case notInGroup = "NotInGroup"
    case groupDoesNotExist = "GroupDoesNotExist"
    case libraryAccessDenied = "LibraryAccessDenied"
    case stateUpdate = "StateUpdate"
    case playQueue = "PlayQueue"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayGroupUpdateType(rawValue: raw) ?? .unknown
    }
}

/// `GroupUpdate`: one envelope, whose `Data` means something different for
/// every `Type`. That is why this decodes by hand — the type has to be read
/// first, and the payload read according to it.
///
/// A payload whose shape is not what its type promises degrades to `.none`
/// rather than failing the update, in keeping with the rest of the client's
/// defensive decoding: knowing that the group changed is worth more than
/// the detail that came with it.
nonisolated struct SyncPlayGroupUpdate: Decodable, Hashable, Sendable {
    nonisolated enum Payload: Hashable, Sendable {
        case group(SyncPlayGroup)
        case userName(String)
        case state(SyncPlayStateUpdate)
        case queue(SyncPlayQueueUpdate)
        /// A bare string: the id in `GroupLeft`, the library in
        /// `LibraryAccessDenied`, nothing in particular elsewhere.
        case message(String?)
        case none
    }

    let groupId: String
    let type: SyncPlayGroupUpdateType
    let payload: Payload

    /// Compare group ids through this: the two spellings Jellyfin uses are
    /// not `==` to each other. See `SyncPlayGroupIdentifier`.
    var normalizedGroupId: String { SyncPlayGroupIdentifier.normalized(groupId) }

    func concerns(groupId other: String) -> Bool {
        SyncPlayGroupIdentifier.matches(groupId, other)
    }

    var group: SyncPlayGroup? {
        if case .group(let group) = payload { return group }
        return nil
    }

    var stateUpdate: SyncPlayStateUpdate? {
        if case .state(let state) = payload { return state }
        return nil
    }

    var queueUpdate: SyncPlayQueueUpdate? {
        if case .queue(let queue) = payload { return queue }
        return nil
    }

    /// The bare string a `UserJoined`, `GroupLeft` or `LibraryAccessDenied`
    /// carries.
    var text: String? {
        switch payload {
        case .userName(let name): name
        case .message(let message): message
        default: nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        groupId = try c.decodeIfPresent(String.self, forKey: "groupId") ?? ""
        type = (try? c.decode(SyncPlayGroupUpdateType.self, forKey: "type")) ?? .unknown
        switch type {
        case .groupJoined:
            payload = (try? c.decode(SyncPlayGroup.self, forKey: "data")).map(Payload.group) ?? .none
        case .userJoined, .userLeft:
            payload = (try? c.decode(String.self, forKey: "data")).map(Payload.userName) ?? .none
        case .stateUpdate:
            payload = (try? c.decode(SyncPlayStateUpdate.self, forKey: "data")).map(Payload.state) ?? .none
        case .playQueue:
            payload = (try? c.decode(SyncPlayQueueUpdate.self, forKey: "data")).map(Payload.queue) ?? .none
        case .groupLeft, .notInGroup, .groupDoesNotExist, .libraryAccessDenied:
            payload = .message(try? c.decode(String.self, forKey: "data"))
        case .unknown:
            payload = .none
        }
    }
}

// MARK: - Reports

/// `SyncPlay/Buffering` and `SyncPlay/Ready` share this body: where this
/// client is, and when it was there. `when` is a server-clock instant
/// produced by `JellyfinTimestamp.string(ServerClock.serverSeconds())`,
/// since the group compares it against its own clock.
nonisolated struct SyncPlayReadinessReport: Encodable, Hashable, Sendable {
    let when: String
    let positionTicks: Int64
    let isPlaying: Bool
    let playlistItemId: String
}

// MARK: - Access

/// `UserPolicy.SyncPlayAccess`. `unknown` covers both a value a future
/// server invents and an answer that never arrived — neither is a denial,
/// and the UI should say it could not check rather than "not allowed".
nonisolated enum SyncPlayAccess: String, Codable, Hashable, Sendable {
    case createAndJoinGroups = "CreateAndJoinGroups"
    case joinGroups = "JoinGroups"
    case none = "None"
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SyncPlayAccess(rawValue: raw) ?? .unknown
    }

    var canJoinGroups: Bool { self == .createAndJoinGroups || self == .joinGroups }
    var canCreateGroups: Bool { self == .createAndJoinGroups }
}

// MARK: - Endpoints

extension JellyfinClient {
    nonisolated struct SyncPlayNewGroupRequest: Encodable {
        let groupName: String
    }

    nonisolated struct SyncPlayJoinRequest: Encodable {
        let groupId: String
    }

    nonisolated struct SyncPlayQueueRequest: Encodable {
        let playingQueue: [String]
        let playingItemPosition: Int
        let startPositionTicks: Int64
    }

    nonisolated struct SyncPlaySeekRequest: Encodable {
        let positionTicks: Int64
    }

    nonisolated struct SyncPlayItemRequest: Encodable {
        let playlistItemId: String
    }

    nonisolated struct SyncPlayPingRequest: Encodable {
        let ping: Int64
    }

    nonisolated struct SyncPlayIgnoreWaitRequest: Encodable {
        let ignoreWait: Bool
    }

    func syncPlayGroups() async throws -> [SyncPlayGroup] {
        try await get("SyncPlay/List")
    }

    /// Creates a group and joins it. The new group's id is not read from
    /// the response: the socket announces it as a `GroupJoined` update
    /// moments later, which is the same path a join takes, so there is one
    /// place that learns the id rather than two.
    func syncPlayCreateGroup(named name: String) async throws {
        try await postVoid("SyncPlay/New", body: SyncPlayNewGroupRequest(groupName: name))
    }

    func syncPlayJoin(groupId: String) async throws {
        try await postVoid("SyncPlay/Join", body: SyncPlayJoinRequest(groupId: groupId))
    }

    func syncPlayLeave() async throws {
        try await postVoid("SyncPlay/Leave")
    }

    /// Replaces the group's queue. `itemIds` are Jellyfin item ids; the
    /// group answers with the `PlaylistItemId`s it assigned them, over the
    /// socket as a `PlayQueue` update.
    func syncPlaySetQueue(itemIds: [String], playingIndex: Int, startPositionTicks: Int64) async throws {
        try await postVoid("SyncPlay/SetNewQueue", body: SyncPlayQueueRequest(
            playingQueue: itemIds,
            playingItemPosition: playingIndex,
            startPositionTicks: startPositionTicks
        ))
    }

    /// Asks the group to play. Nothing happens locally: the server answers
    /// every member with a command naming the instant to start at.
    func syncPlayUnpause() async throws {
        try await postVoid("SyncPlay/Unpause")
    }

    func syncPlayPause() async throws {
        try await postVoid("SyncPlay/Pause")
    }

    func syncPlayStop() async throws {
        try await postVoid("SyncPlay/Stop")
    }

    func syncPlaySeek(positionTicks: Int64) async throws {
        try await postVoid("SyncPlay/Seek", body: SyncPlaySeekRequest(positionTicks: positionTicks))
    }

    func syncPlayNextItem(playlistItemId: String) async throws {
        try await postVoid("SyncPlay/NextItem", body: SyncPlayItemRequest(playlistItemId: playlistItemId))
    }

    func syncPlayPreviousItem(playlistItemId: String) async throws {
        try await postVoid("SyncPlay/PreviousItem", body: SyncPlayItemRequest(playlistItemId: playlistItemId))
    }

    func syncPlaySetPlaylistItem(playlistItemId: String) async throws {
        try await postVoid("SyncPlay/SetPlaylistItem", body: SyncPlayItemRequest(playlistItemId: playlistItemId))
    }

    /// Tells the group this client is not ready. Everyone else waits, which
    /// is the whole bargain of SyncPlay: the slowest device sets the pace.
    func syncPlayReportBuffering(_ report: SyncPlayReadinessReport) async throws {
        try await postVoid("SyncPlay/Buffering", body: report)
    }

    func syncPlayReportReady(_ report: SyncPlayReadinessReport) async throws {
        try await postVoid("SyncPlay/Ready", body: report)
    }

    /// Reports this client's one-way latency so the group can allow for it
    /// when it picks an instant to start at.
    func syncPlayPing(milliseconds: Int64) async throws {
        try await postVoid("SyncPlay/Ping", body: SyncPlayPingRequest(ping: milliseconds))
    }

    /// Takes this client out of the group's readiness accounting: it will
    /// be started at the same instant as everyone else and no longer holds
    /// them up when it is behind.
    func syncPlaySetIgnoreWait(_ ignoreWait: Bool) async throws {
        try await postVoid("SyncPlay/SetIgnoreWait", body: SyncPlayIgnoreWaitRequest(ignoreWait: ignoreWait))
    }

    /// What this account is allowed to do with groups. `unknown` when the
    /// server could not be asked — see `SyncPlayAccess`.
    func syncPlayAccess() async -> SyncPlayAccess {
        guard let user = try? await currentUser() else { return .unknown }
        return user.policy?.syncPlayAccess ?? .unknown
    }

    /// Whether this server serves SyncPlay at all. A probe: its failure is
    /// an answer rather than a fault, so it is never reported as an
    /// incident.
    func isSyncPlayAvailable() async -> Bool {
        do {
            let _: [SyncPlayGroup] = try await get("SyncPlay/List", probe: true)
            return true
        } catch {
            return false
        }
    }
}

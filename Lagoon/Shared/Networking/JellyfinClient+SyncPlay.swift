import Foundation

// SyncPlay: shared playback across the devices in a group.
//
// - Every server enum decodes with an `unknown` fallback, so a new value
//   never fails the whole update.
// - `When`, `EmittedAt` and `LastUpdate` stay `String`: they are instants on
//   the server's clock, converted only through `JellyfinTimestamp` with
//   `ServerClock`'s offset. Never decode them as `Date`.

// MARK: - Identifiers

/// Jellyfin spells a group id two ways: undashed hex in `GroupId` and
/// `SyncPlay/New`, dashed in the `GroupLeft` payload. Compare through here,
/// never with `==` on the raw strings.
nonisolated enum SyncPlayGroupIdentifier {
    static func normalized(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    static func matches(_ one: String, _ other: String) -> Bool {
        normalized(one) == normalized(other)
    }

    /// Jellyfin's "no item" id: an all-zero GUID.
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

/// `SendCommand`: what every member should do, and when. `when` is an
/// instant on the server's clock, not a delay; act on it via `ServerClock`.
nonisolated struct SyncPlayCommand: Decodable, Hashable, Sendable {
    let groupId: String
    let playlistItemId: String
    /// Server wall clock: act at this instant.
    let when: String
    let positionTicks: Int64
    let command: SyncPlayCommandKind
    /// Server wall clock: when the server sent this.
    let emittedAt: String

    /// False for the `Stop` a new group is greeted with: nothing is queued.
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
    /// Commands name this, not the item: a title can be queued twice.
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
    /// Server wall clock. Drop updates older than the last one applied.
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
    /// The `PlaybackRequestType` behind the change. A label only; never
    /// branched on.
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

/// `GroupUpdate`: `Data` depends on `Type`, so this decodes by hand. A
/// malformed payload degrades to `.none` rather than failing the update.
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

/// Body of `SyncPlay/Buffering` and `SyncPlay/Ready`. `when` is a
/// server-clock instant: `JellyfinTimestamp.string(ServerClock.serverSeconds())`.
nonisolated struct SyncPlayReadinessReport: Encodable, Hashable, Sendable {
    let when: String
    let positionTicks: Int64
    let isPlaying: Bool
    let playlistItemId: String
}

// MARK: - Access

/// `UserPolicy.SyncPlayAccess`. `unknown` (new value or no answer) is not
/// a denial; the UI says it could not check.
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

    /// Creates and joins a group. The id arrives over the socket as
    /// `GroupJoined`, the same path a join takes.
    func syncPlayCreateGroup(named name: String) async throws {
        try await postVoid("SyncPlay/New", body: SyncPlayNewGroupRequest(groupName: name))
    }

    func syncPlayJoin(groupId: String) async throws {
        try await postVoid("SyncPlay/Join", body: SyncPlayJoinRequest(groupId: groupId))
    }

    func syncPlayLeave() async throws {
        try await postVoid("SyncPlay/Leave")
    }

    /// Replaces the group's queue. The assigned `PlaylistItemId`s arrive
    /// over the socket as a `PlayQueue` update.
    func syncPlaySetQueue(itemIds: [String], playingIndex: Int, startPositionTicks: Int64) async throws {
        try await postVoid("SyncPlay/SetNewQueue", body: SyncPlayQueueRequest(
            playingQueue: itemIds,
            playingItemPosition: playingIndex,
            startPositionTicks: startPositionTicks
        ))
    }

    /// Asks the group to play. Nothing happens locally until the server's
    /// command arrives.
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

    /// Tells the group this client is not ready; everyone else waits.
    func syncPlayReportBuffering(_ report: SyncPlayReadinessReport) async throws {
        try await postVoid("SyncPlay/Buffering", body: report)
    }

    func syncPlayReportReady(_ report: SyncPlayReadinessReport) async throws {
        try await postVoid("SyncPlay/Ready", body: report)
    }

    /// Reports one-way latency, which the group allows for when scheduling.
    func syncPlayPing(milliseconds: Int64) async throws {
        try await postVoid("SyncPlay/Ping", body: SyncPlayPingRequest(ping: milliseconds))
    }

    /// Stops this client from holding the group up when it is behind.
    func syncPlaySetIgnoreWait(_ ignoreWait: Bool) async throws {
        try await postVoid("SyncPlay/SetIgnoreWait", body: SyncPlayIgnoreWaitRequest(ignoreWait: ignoreWait))
    }

    /// `unknown` when the server could not be asked.
    func syncPlayAccess() async -> SyncPlayAccess {
        guard let user = try? await currentUser() else { return .unknown }
        return user.policy?.syncPlayAccess ?? .unknown
    }

    /// Whether this server serves SyncPlay. A probe, so never reported.
    func isSyncPlayAvailable() async -> Bool {
        do {
            let _: [SyncPlayGroup] = try await get("SyncPlay/List", probe: true)
            return true
        } catch {
            return false
        }
    }
}

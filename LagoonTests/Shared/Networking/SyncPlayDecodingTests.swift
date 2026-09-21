import Foundation
import Testing
@testable import Lagoon

/// The SyncPlay wire, pinned against payloads captured from fixture 12.0.0
/// on 2026-09-14. Every group update means something different by
/// its `Type`, so each one gets a fixture; the two decoding rules that carry
/// the feature — an unknown enumeration never fails a message, and a group
/// id compares across Jellyfin's two spellings of it — get their own.
@Suite("SyncPlay decoding")
struct SyncPlayDecodingTests {
    // MARK: - Group updates

    @Test func groupJoinedCarriesTheGroup() throws {
        let update = try groupUpdate("""
        {"GroupId":"ea9615382d214f9c9313c26fbd3bad89","Type":"GroupJoined",
         "Data":{"GroupId":"ea9615382d214f9c9313c26fbd3bad89","GroupName":"Film night",
                 "State":"Idle","Participants":["Jaagop"],"LastUpdatedAt":"2026-09-14T11:44:16.1864573Z"}}
        """)
        #expect(update.type == .groupJoined)
        let group = try #require(update.group)
        #expect(group.groupName == "Film night")
        #expect(group.state == .idle)
        #expect(group.participants == ["Jaagop"])
        #expect(group.id == "ea9615382d214f9c9313c26fbd3bad89")
    }

    @Test func userJoinedAndUserLeftCarryANameNotAnId() throws {
        let joined = try groupUpdate(#"{"GroupId":"ea96","Type":"UserJoined","Data":"Jaagop"}"#)
        #expect(joined.type == .userJoined)
        #expect(joined.text == "Jaagop")
        let left = try groupUpdate(#"{"GroupId":"ea96","Type":"UserLeft","Data":"Jaagop"}"#)
        #expect(left.type == .userLeft)
        #expect(left.text == "Jaagop")
    }

    /// The one place the server uses the dashed spelling of the group id.
    @Test func groupLeftCarriesTheDashedIdAndStillMatchesTheGroup() throws {
        let update = try groupUpdate("""
        {"GroupId":"ea9615382d214f9c9313c26fbd3bad89","Type":"GroupLeft",
         "Data":"ea961538-2d21-4f9c-9313-c26fbd3bad89"}
        """)
        #expect(update.type == .groupLeft)
        let payload = try #require(update.text)
        #expect(SyncPlayGroupIdentifier.matches(payload, update.groupId))
        #expect(payload != update.groupId)
    }

    @Test func stateUpdateCarriesTheStateAndItsReason() throws {
        let update = try groupUpdate(#"{"GroupId":"ea96","Type":"StateUpdate","Data":{"State":"Playing","Reason":"Unpause"}}"#)
        let state = try #require(update.stateUpdate)
        #expect(state.state == .playing)
        #expect(state.reason == "Unpause")
    }

    @Test func playQueueCarriesTheQueueAndWhereInItTheGroupIs() throws {
        let update = try groupUpdate("""
        {"GroupId":"ea9615382d214f9c9313c26fbd3bad89","Type":"PlayQueue",
         "Data":{"Reason":"NewPlaylist","LastUpdate":"2026-09-14T11:44:16.1864573Z",
                 "Playlist":[{"ItemId":"143aa6bd228bf45c7736c69e0a3cb6e6",
                              "PlaylistItemId":"8a3228756d3e439f9b8cd5bdbfe8deb6"}],
                 "PlayingItemIndex":0,"StartPositionTicks":0,"IsPlaying":false,
                 "ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}
        """)
        let queue = try #require(update.queueUpdate)
        #expect(queue.reason == .newPlaylist)
        #expect(queue.playlist.count == 1)
        #expect(queue.playingItem?.itemId == "143aa6bd228bf45c7736c69e0a3cb6e6")
        #expect(queue.playingItem?.playlistItemId == "8a3228756d3e439f9b8cd5bdbfe8deb6")
        #expect(queue.isPlaying == false)
        #expect(queue.shuffleMode == "Sorted")
        #expect(JellyfinTimestamp.seconds(queue.lastUpdate) != nil)
    }

    @Test func theRefusalUpdatesDecodeWithOrWithoutAMessage() throws {
        #expect(try groupUpdate(#"{"GroupId":"ea96","Type":"NotInGroup"}"#).type == .notInGroup)
        #expect(try groupUpdate(#"{"GroupId":"ea96","Type":"GroupDoesNotExist"}"#).type == .groupDoesNotExist)
        let denied = try groupUpdate(#"{"GroupId":"ea96","Type":"LibraryAccessDenied","Data":"Movies"}"#)
        #expect(denied.type == .libraryAccessDenied)
        #expect(denied.text == "Movies")
    }

    /// A type this build has never heard of still decodes, so the update is
    /// ignored rather than taking the socket's message with it.
    @Test func anUnknownUpdateTypeDecodesAsUnknown() throws {
        let update = try groupUpdate(#"{"GroupId":"ea96","Type":"SomethingNew","Data":{"Whatever":1}}"#)
        #expect(update.type == .unknown)
        #expect(update.payload == .none)
    }

    /// A payload that is not the shape its type promises loses the detail,
    /// not the update.
    @Test func aPayloadOfTheWrongShapeDegradesToNone() throws {
        let update = try groupUpdate(#"{"GroupId":"ea96","Type":"GroupJoined","Data":"not a group"}"#)
        #expect(update.type == .groupJoined)
        #expect(update.group == nil)
        #expect(update.payload == .none)
    }

    // MARK: - Commands

    /// The `Stop` a brand new group is greeted with: no queue yet, so the
    /// playlist item is an all-zero GUID.
    @Test func theEmptyPlaylistItemOnANewGroupsStopIsRecognised() throws {
        let command = try decode(SyncPlayCommand.self, """
        {"GroupId":"ea9615382d214f9c9313c26fbd3bad89","PlaylistItemId":"00000000000000000000000000000000",
         "When":"2026-09-14T11:44:16.1864573Z","PositionTicks":0,"Command":"Stop",
         "EmittedAt":"2026-09-14T11:44:16.1864573Z"}
        """)
        #expect(command.command == .stop)
        #expect(!command.hasPlaylistItem)
        #expect(SyncPlayGroupIdentifier.isEmptyIdentifier("00000000-0000-0000-0000-000000000000"))
    }

    @Test func aSeekCommandKeepsItsPositionInTicks() throws {
        let command = try decode(SyncPlayCommand.self, """
        {"GroupId":"ea96","PlaylistItemId":"8a32","When":"2026-09-14T11:44:21.3560439Z",
         "PositionTicks":600000000,"Command":"Seek","EmittedAt":"2026-09-14T11:44:20.3560554Z"}
        """)
        #expect(command.command == .seek)
        #expect(command.positionTicks == 600_000_000)
        #expect(abs(command.positionSeconds - 60) < 1e-9)
    }

    @Test func anUnknownCommandDoesNotFailTheMessage() throws {
        let command = try decode(SyncPlayCommand.self, """
        {"GroupId":"ea96","PlaylistItemId":"8a32","When":"2026-09-14T11:44:21.3560439Z",
         "PositionTicks":0,"Command":"Teleport","EmittedAt":"2026-09-14T11:44:20.3560554Z"}
        """)
        #expect(command.command == .unknown)
        #expect(command.whenSeconds != nil)
    }

    // MARK: - Groups and access

    @Test func anEmptyGroupListIsAnEmptyList() throws {
        #expect(try decode([SyncPlayGroup].self, "[]").isEmpty)
    }

    @Test func anUnknownGroupStateDoesNotFailTheGroup() throws {
        let group = try decode(SyncPlayGroup.self, #"{"GroupId":"ea96","GroupName":"N","State":"Rewinding"}"#)
        #expect(group.state == .unknown)
        #expect(group.participants.isEmpty)
    }

    /// `SyncPlayAccess` rides on the user policy the client already reads,
    /// and an unrecognised value is not a denial.
    @Test func theUserPolicyCarriesSyncPlayAccess() throws {
        let allowed = try decode(UserPolicy.self, #"{"SyncPlayAccess":"CreateAndJoinGroups"}"#)
        #expect(allowed.syncPlayAccess == .createAndJoinGroups)
        #expect(allowed.syncPlayAccess?.canCreateGroups == true)

        let joiner = try decode(UserPolicy.self, #"{"SyncPlayAccess":"JoinGroups"}"#)
        #expect(joiner.syncPlayAccess?.canCreateGroups == false)
        #expect(joiner.syncPlayAccess?.canJoinGroups == true)

        #expect(try decode(UserPolicy.self, #"{"SyncPlayAccess":"None"}"#).syncPlayAccess == SyncPlayAccess.none)
        #expect(try decode(UserPolicy.self, #"{"SyncPlayAccess":"Whatever"}"#).syncPlayAccess == .unknown)
        #expect(try decode(UserPolicy.self, "{}").syncPlayAccess == nil)
    }

    @Test func normalizingAGroupIdIsCaseAndDashInsensitive() {
        #expect(SyncPlayGroupIdentifier.matches("EA961538-2D21-4F9C-9313-C26FBD3BAD89",
                                                "ea9615382d214f9c9313c26fbd3bad89"))
        #expect(!SyncPlayGroupIdentifier.matches("ea9615382d214f9c9313c26fbd3bad89",
                                                 "ffffffffffffffffffffffffffffffff"))
        #expect(SyncPlayGroupIdentifier.isEmptyIdentifier(""))
        #expect(!SyncPlayGroupIdentifier.isEmptyIdentifier("ea96"))
    }

    // MARK: - Encoding

    /// The readiness report goes back up PascalCase, through the client's
    /// global key strategy and with no CodingKeys of its own.
    @Test func theReadinessReportEncodesWithPascalCaseKeys() throws {
        let report = SyncPlayReadinessReport(
            // A fraction a Double holds exactly; the seventh digit is
            // JellyfinTimestampTests' business, not this test's.
            when: JellyfinTimestamp.string(1_789_386_256.25),
            positionTicks: 600_000_000,
            isPlaying: true,
            playlistItemId: "8a3228756d3e439f9b8cd5bdbfe8deb6"
        )
        let data = try JellyfinClient.encoder.encode(report)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["When", "PositionTicks", "IsPlaying", "PlaylistItemId"])
        #expect(object["When"] as? String == "2026-09-14T11:44:16.2500000Z")
        #expect(object["PositionTicks"] as? Int == 600_000_000)
        #expect(object["IsPlaying"] as? Bool == true)
    }

    @Test func theQueueRequestEncodesWithPascalCaseKeys() throws {
        let data = try JellyfinClient.encoder.encode(JellyfinClient.SyncPlayQueueRequest(
            playingQueue: ["143aa6bd228bf45c7736c69e0a3cb6e6"],
            playingItemPosition: 0,
            startPositionTicks: 0
        ))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["PlayingQueue", "PlayingItemPosition", "StartPositionTicks"])
    }

    // MARK: - Helpers

    private func groupUpdate(_ json: String) throws -> SyncPlayGroupUpdate {
        try decode(SyncPlayGroupUpdate.self, json)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JellyfinClient.decoder.decode(type, from: Data(json.utf8))
    }
}

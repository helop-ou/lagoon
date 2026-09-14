import Foundation
import Testing
@testable import Lagoon

/// The rules a Watch Together member follows, against the same fixture
/// 12.0.0 payloads the wire tests decode (HEL-172). Every one of these is a
/// rule that, got wrong, shows up as two televisions playing different
/// things — which is why they live in a pure reducer and not inside an
/// `async` method of a store.
@Suite("SyncPlay session")
struct SyncPlaySessionTests {
    static let groupID = "ea9615382d214f9c9313c26fbd3bad89"
    static let itemID = "143aa6bd228bf45c7736c69e0a3cb6e6"
    static let playlistItemID = "8a3228756d3e439f9b8cd5bdbfe8deb6"

    // MARK: - Joining

    @Test func joiningAdoptsTheGroupAndItsMembers() throws {
        var session = SyncPlayGroupSession()
        let effects = session.apply(try Self.groupJoined())
        #expect(session.isJoined)
        #expect(session.groupName == "Film night")
        #expect(session.participants == ["Jaagop"])
        #expect(session.state == .idle)
        #expect(effects == [.notice(.joined(group: "Film night"))])
        // The join instant is what later decides which commands are older
        // than this membership.
        #expect(session.joinedAtServerSeconds == JellyfinTimestamp.seconds("2026-09-14T11:44:16.1864573Z"))
    }

    @Test func anUpdateForAnotherGroupIsNotOurs() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let other = try Self.update("""
        {"GroupId":"0000000000000000000000000000ffff","Type":"UserJoined","Data":"Someone"}
        """)
        #expect(session.apply(other).isEmpty)
        #expect(session.participants == ["Jaagop"])
    }

    @Test func membersComeAndGo() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.update(#"{"GroupId":"\#(Self.groupID)","Type":"UserJoined","Data":"Sam"}"#))
        #expect(session.participants == ["Jaagop", "Sam"])
        let left = session.apply(try Self.update(#"{"GroupId":"\#(Self.groupID)","Type":"UserLeft","Data":"Jaagop"}"#))
        #expect(session.participants == ["Sam"])
        #expect(left == [.notice(.userLeft("Jaagop"))])
    }

    /// The dashed spelling of the group id has to be recognised as ours, or
    /// the member never notices it has been removed.
    @Test func theDashedGroupLeftEndsTheMembership() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let effects = session.apply(try Self.update("""
        {"GroupId":"\(Self.groupID)","Type":"GroupLeft","Data":"ea961538-2d21-4f9c-9313-c26fbd3bad89"}
        """))
        #expect(effects.contains(.left(reason: .leftGroup)))
        #expect(!session.isJoined)
        #expect(session.lastCommand == nil)
    }

    /// A refusal names no group, and dropping it would leave the session
    /// convinced it is still a member.
    @Test func aRefusalWithNoGroupIdStillEndsTheMembership() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let effects = session.apply(try Self.update(#"{"Type":"NotInGroup"}"#))
        #expect(effects.contains(.left(reason: .notInGroup)))
        #expect(!session.isJoined)
    }

    @Test func aStateChangeIsAnnouncedOnceAndOnlyWhenItChanges() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let playing = try Self.update(#"{"GroupId":"\#(Self.groupID)","Type":"StateUpdate","Data":{"State":"Playing","Reason":"Unpause"}}"#)
        #expect(session.apply(playing) == [.notice(.state(.playing, reason: "Unpause"))])
        #expect(session.state == .playing)
        #expect(session.apply(playing).isEmpty)
    }

    // MARK: - The queue

    @Test func aNewPlaylistAsksForTheItemAtItsStartPosition() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let effects = session.apply(try Self.playQueue(
            reason: "NewPlaylist",
            lastUpdate: "2026-09-14T11:45:00.0000000Z",
            startPositionTicks: 1_200_000_000
        ))
        #expect(effects == [.loadItem(
            itemId: Self.itemID,
            playlistItemId: Self.playlistItemID,
            positionSeconds: 120
        )])
        #expect(session.currentPlaylistItemId == Self.playlistItemID)
        #expect(session.startSeconds == 120)
    }

    /// The same item arriving again — a reorder, a second member joining —
    /// must not restart what is on screen.
    @Test func aQueueUpdateThatDoesNotChangeTheItemLoadsNothing() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.playQueue(reason: "NewPlaylist", lastUpdate: "2026-09-14T11:45:00.0000000Z"))
        let again = session.apply(try Self.playQueue(
            reason: "SetCurrentItem",
            lastUpdate: "2026-09-14T11:45:10.0000000Z"
        ))
        #expect(again.isEmpty)
    }

    @Test func aQueueUpdateOlderThanTheOneAppliedIsDropped() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.playQueue(reason: "NewPlaylist", lastUpdate: "2026-09-14T11:45:10.0000000Z"))
        let stale = session.apply(try Self.playQueue(
            reason: "NewPlaylist",
            lastUpdate: "2026-09-14T11:45:00.0000000Z",
            playlistItemId: "00000000000000000000000000000001"
        ))
        #expect(stale.isEmpty)
        #expect(session.currentPlaylistItemId == Self.playlistItemID)
    }

    /// Queueing something behind the current item is not a reason to
    /// reload the current item.
    @Test func queueingSomethingBehindTheCurrentItemLoadsNothing() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.playQueue(reason: "NewPlaylist", lastUpdate: "2026-09-14T11:45:00.0000000Z"))
        let queued = session.apply(try Self.update("""
        {"GroupId":"\(Self.groupID)","Type":"PlayQueue",
         "Data":{"Reason":"Queue","LastUpdate":"2026-09-14T11:46:00.0000000Z",
                 "Playlist":[{"ItemId":"\(Self.itemID)","PlaylistItemId":"\(Self.playlistItemID)"},
                             {"ItemId":"b2","PlaylistItemId":"p2"}],
                 "PlayingItemIndex":0,"StartPositionTicks":0,"IsPlaying":true,
                 "ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}
        """))
        #expect(queued.isEmpty)
    }

    @Test func movingToTheNextItemLoadsIt() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.playQueue(reason: "NewPlaylist", lastUpdate: "2026-09-14T11:45:00.0000000Z"))
        let next = session.apply(try Self.update("""
        {"GroupId":"\(Self.groupID)","Type":"PlayQueue",
         "Data":{"Reason":"NextItem","LastUpdate":"2026-09-14T11:47:00.0000000Z",
                 "Playlist":[{"ItemId":"\(Self.itemID)","PlaylistItemId":"\(Self.playlistItemID)"},
                             {"ItemId":"b2","PlaylistItemId":"p2"}],
                 "PlayingItemIndex":1,"StartPositionTicks":0,"IsPlaying":true,
                 "ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}
        """))
        #expect(next == [.loadItem(itemId: "b2", playlistItemId: "p2", positionSeconds: 0)])
    }

    // MARK: - Commands

    @Test func aCommandForTheCurrentItemIsAccepted() throws {
        var session = try Self.joinedWithQueue()
        let command = try Self.command(kind: "Unpause", positionTicks: 0)
        #expect(session.accepts(command))
        session.record(command)
        #expect(session.lastCommand == command)
    }

    /// The greeting a freshly created group sends: nothing is queued, so
    /// there is nothing to stop.
    @Test func theAllZeroStopThatGreetsANewGroupIsIgnored() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        let stop = try Self.command(
            kind: "Stop",
            positionTicks: 0,
            playlistItemId: "00000000-0000-0000-0000-000000000000"
        )
        #expect(!session.accepts(stop))
    }

    @Test func aCommandEmittedBeforeThisMemberJoinedIsIgnored() throws {
        let session = try Self.joinedWithQueue()
        let old = try Self.command(
            kind: "Unpause",
            positionTicks: 0,
            emittedAt: "2026-09-14T11:44:00.0000000Z"
        )
        #expect(!session.accepts(old))
        let new = try Self.command(
            kind: "Unpause",
            positionTicks: 0,
            emittedAt: "2026-09-14T11:46:00.0000000Z"
        )
        #expect(session.accepts(new))
    }

    @Test func aCommandForAnotherItemIsIgnoredUnlessItIsStop() throws {
        let session = try Self.joinedWithQueue()
        let elsewhere = try Self.command(kind: "Seek", positionTicks: 0, playlistItemId: "p2")
        #expect(!session.accepts(elsewhere))
        let stop = try Self.command(kind: "Stop", positionTicks: 0, playlistItemId: "p2")
        #expect(session.accepts(stop))
    }

    @Test func theSameCommandTwiceIsTakenOnce() throws {
        var session = try Self.joinedWithQueue()
        let command = try Self.command(kind: "Pause", positionTicks: 600_000_000)
        #expect(session.accepts(command))
        session.record(command)
        #expect(!session.accepts(command))
        // A genuine re-send differs in `EmittedAt` alone and is still the
        // same instruction.
        let resent = try Self.command(
            kind: "Pause",
            positionTicks: 600_000_000,
            emittedAt: "2026-09-14T11:47:00.0000000Z"
        )
        #expect(!session.accepts(resent))
        // A different instant is a different instruction.
        let later = try Self.command(
            kind: "Pause",
            positionTicks: 600_000_000,
            when: "2026-09-14T11:48:00.0000000Z"
        )
        #expect(session.accepts(later))
    }

    /// The server answers a `Ready` that names a position more than half a
    /// second from the group's with a `Seek` built out of the group's own
    /// state — the same `When`, the same `PositionTicks`, only `EmittedAt`
    /// moved on. Taking that for a re-send is what left a member sitting
    /// where it was, with nothing more to report, and the group waiting on
    /// it past thirty seconds (HEL-172).
    @Test func aResentSeekIsACorrectionAndIsTakenAgain() throws {
        var session = try Self.joinedWithQueue()
        let seek = try Self.command(kind: "Seek", positionTicks: 1_200_000_000)
        #expect(session.accepts(seek))
        session.record(seek)
        let correcting = try Self.command(
            kind: "Seek",
            positionTicks: 1_200_000_000,
            emittedAt: "2026-09-14T11:47:00.0000000Z"
        )
        #expect(session.accepts(correcting))
    }

    @Test func nothingIsAcceptedWithoutAGroup() throws {
        let session = SyncPlayGroupSession()
        #expect(!session.accepts(try Self.command(kind: "Unpause", positionTicks: 0)))
    }

    @Test func aCommandTheServerInventedIsIgnored() throws {
        let session = try Self.joinedWithQueue()
        #expect(!session.accepts(try Self.command(kind: "Rewind", positionTicks: 0)))
    }

    // MARK: - Where the group is

    /// What a member coming back to the player has to open at: the group
    /// has been watching all the while, and opening where the last command
    /// left it makes the server drag this member forward — with everyone
    /// else held up until it arrives (HEL-172).
    @Test func aRunningGroupHasMovedOnSinceItsLastCommand() throws {
        var session = try Self.joinedWithQueue()
        let started = "2026-09-14T11:46:30.0000000Z"
        session.record(try Self.command(kind: "Unpause", positionTicks: 1_000_000_000, when: started))
        let when = try #require(JellyfinTimestamp.seconds(started))
        #expect(session.positionSeconds(atServerSeconds: when + 90) == 190)
        // Before the instant it names, an unpause is a position, not a
        // clock that has been running.
        #expect(session.positionSeconds(atServerSeconds: when - 1) == 100)
    }

    @Test func aStoppedGroupIsWhereItsLastCommandLeftIt() throws {
        var session = try Self.joinedWithQueue()
        let when = try #require(JellyfinTimestamp.seconds("2026-09-14T11:46:30.0000000Z"))
        session.record(try Self.command(kind: "Pause", positionTicks: 1_000_000_000))
        #expect(session.positionSeconds(atServerSeconds: when + 90) == 100)
        session.record(try Self.command(kind: "Seek", positionTicks: 3_000_000_000))
        #expect(session.positionSeconds(atServerSeconds: when + 90) == 300)
    }

    /// Nothing has been commanded yet: the queue's own start is the only
    /// answer there is.
    @Test func aGroupThatHasNotBeenToldAnythingIsAtItsQueueStart() throws {
        var session = SyncPlayGroupSession()
        _ = session.apply(try Self.groupJoined())
        _ = session.apply(try Self.playQueue(
            reason: "NewPlaylist",
            lastUpdate: "2026-09-14T11:45:00.0000000Z",
            startPositionTicks: 600_000_000
        ))
        #expect(session.positionSeconds(atServerSeconds: 1_000_000) == 60)
    }

    // MARK: - Fixtures

    static func update(_ json: String) throws -> SyncPlayGroupUpdate {
        try JellyfinClient.decoder.decode(SyncPlayGroupUpdate.self, from: Data(json.utf8))
    }

    static func groupJoined() throws -> SyncPlayGroupUpdate {
        try update("""
        {"GroupId":"\(groupID)","Type":"GroupJoined",
         "Data":{"GroupId":"\(groupID)","GroupName":"Film night","State":"Idle",
                 "Participants":["Jaagop"],"LastUpdatedAt":"2026-09-14T11:44:16.1864573Z"}}
        """)
    }

    static func playQueue(
        reason: String,
        lastUpdate: String,
        playlistItemId: String = playlistItemID,
        startPositionTicks: Int64 = 0
    ) throws -> SyncPlayGroupUpdate {
        try update("""
        {"GroupId":"\(groupID)","Type":"PlayQueue",
         "Data":{"Reason":"\(reason)","LastUpdate":"\(lastUpdate)",
                 "Playlist":[{"ItemId":"\(itemID)","PlaylistItemId":"\(playlistItemId)"}],
                 "PlayingItemIndex":0,"StartPositionTicks":\(startPositionTicks),"IsPlaying":false,
                 "ShuffleMode":"Sorted","RepeatMode":"RepeatNone"}}
        """)
    }

    static func command(
        kind: String,
        positionTicks: Int64,
        playlistItemId: String = playlistItemID,
        when: String = "2026-09-14T11:46:30.0000000Z",
        emittedAt: String = "2026-09-14T11:46:29.5000000Z"
    ) throws -> SyncPlayCommand {
        let json = """
        {"GroupId":"\(groupID)","PlaylistItemId":"\(playlistItemId)","When":"\(when)",
         "PositionTicks":\(positionTicks),"Command":"\(kind)","EmittedAt":"\(emittedAt)"}
        """
        return try JellyfinClient.decoder.decode(SyncPlayCommand.self, from: Data(json.utf8))
    }

    static func joinedWithQueue() throws -> SyncPlayGroupSession {
        var session = SyncPlayGroupSession()
        _ = session.apply(try groupJoined())
        _ = session.apply(try playQueue(reason: "NewPlaylist", lastUpdate: "2026-09-14T11:45:00.0000000Z"))
        return session
    }
}

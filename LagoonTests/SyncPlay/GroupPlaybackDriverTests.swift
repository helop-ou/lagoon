import Foundation
import Testing
@testable import Lagoon

/// Where a group start puts the playhead, and how far off a member may be
/// before a start or a pause re-seeks.
@Suite("Group playback driver")
struct GroupPlaybackDriverTests {
    /// The group starts in a second: everyone presents the command's position.
    @Test func aFutureStartPresentsTheCommandsPosition() {
        #expect(GroupPlaybackDriver.unpauseTarget(position: 30, when: 1_001, now: 1_000) == 30)
    }

    /// A re-sent Unpause for a group already running: join where it is now.
    @Test func aPastStartPresentsWhereTheGroupIsNow() {
        #expect(GroupPlaybackDriver.unpauseTarget(position: 30, when: 1_000, now: 1_004) == 34)
        #expect(GroupPlaybackDriver.unpauseTarget(position: 30, when: 1_000, now: 1_000) == 30)
    }

    /// The start anchor absorbs half a second; a seek would re-prime for nothing.
    @Test func aStartReseeksOnlyBeyondHalfASecond() {
        #expect(!GroupPlaybackDriver.startNeedsSeek(from: 10, to: 10.5))
        #expect(!GroupPlaybackDriver.startNeedsSeek(from: 10.25, to: 10))
        #expect(GroupPlaybackDriver.startNeedsSeek(from: 10, to: 10.75))
        #expect(GroupPlaybackDriver.startNeedsSeek(from: 10.75, to: 10))
    }

    /// A pause has no anchor, so a tenth of a second already shows.
    @Test func aPauseReseeksBeyondATenthOfASecond() {
        #expect(!GroupPlaybackDriver.pauseNeedsSeek(from: 10, to: 10.0625))
        #expect(GroupPlaybackDriver.pauseNeedsSeek(from: 10, to: 10.25))
        #expect(GroupPlaybackDriver.pauseNeedsSeek(from: 10.25, to: 10))
    }
}

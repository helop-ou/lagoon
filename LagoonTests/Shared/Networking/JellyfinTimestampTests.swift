import Foundation
import Testing
@testable import Lagoon

/// The one place a Jellyfin wall clock becomes a number, so the
/// cases that broke `ISO8601DateFormatter` are pinned here: .NET's seventh
/// fractional digit, and the fact that the digit count varies between two
/// responses a millisecond apart.
@Suite("Jellyfin timestamp")
struct JellyfinTimestampTests {
    /// Both spellings came back from the fixture server, 12.0.0 in the same response:
    /// six digits on the reception time, seven on the transmission time.
    @Test func parsesSixAndSevenFractionalDigitsAlike() throws {
        let six = try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21.280578Z"))
        let seven = try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21.2805781Z"))
        #expect(abs(six - 1_789_386_141.280578) < 1e-5)
        #expect(abs(seven - six) < 1e-5)
    }

    @Test func keepsSubMillisecondPrecision() throws {
        let early = try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21.2800000Z"))
        let late = try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21.2801000Z"))
        #expect(abs((late - early) - 0.0001) < 1e-5)
    }

    @Test func acceptsNoFractionAndEveryUTCSpelling() throws {
        let plain = try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21Z"))
        #expect(try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21+00:00")) == plain)
        #expect(try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21-00:00")) == plain)
        #expect(try #require(JellyfinTimestamp.seconds("2026-09-14T11:42:21")) == plain)
    }

    /// A real offset is refused rather than read as UTC: a group scheduled
    /// an hour out is worse than one that visibly could not read the time.
    @Test func refusesWhatItCannotReadHonestly() {
        #expect(JellyfinTimestamp.seconds("2026-09-14T11:42:21+02:00") == nil)
        #expect(JellyfinTimestamp.seconds("2026-09-14 11:42:21Z") == nil)
        #expect(JellyfinTimestamp.seconds("2026-13-14T11:42:21Z") == nil)
        #expect(JellyfinTimestamp.seconds("2026-09-14T24:42:21Z") == nil)
        #expect(JellyfinTimestamp.seconds("26-09-14T11:42:21Z") == nil)
        #expect(JellyfinTimestamp.seconds("2026-09-14T11:42:21.Z") == nil)
        #expect(JellyfinTimestamp.seconds("") == nil)
        #expect(JellyfinTimestamp.seconds("not a time") == nil)
    }

    @Test func leapDaysAndYearBoundariesSurviveTheManualParse() throws {
        #expect(JellyfinTimestamp.seconds("2024-02-29T00:00:00Z") == 1_709_164_800)
        #expect(JellyfinTimestamp.seconds("2026-01-01T00:00:00Z") == 1_767_225_600)
        #expect(JellyfinTimestamp.seconds("1970-01-01T00:00:00Z") == 0)
    }

    /// What goes back to the server in `SyncPlay/Ready`: always seven
    /// digits and a `Z`, whatever came in.
    @Test func writesTheDotNetSpelling() {
        #expect(JellyfinTimestamp.string(0) == "1970-01-01T00:00:00.0000000Z")
        #expect(JellyfinTimestamp.string(1_789_386_141.25) == "2026-09-14T11:42:21.2500000Z")
    }

    @Test func roundTripsAServerInstant() throws {
        let wire = "2026-09-14T11:44:16.1864573Z"
        let seconds = try #require(JellyfinTimestamp.seconds(wire))
        let again = try #require(JellyfinTimestamp.seconds(JellyfinTimestamp.string(seconds)))
        #expect(abs(again - seconds) < 1e-5)
    }

    /// Rounding the fraction up must carry into the second rather than
    /// print a tenth digit that does not exist.
    @Test func aFractionThatRoundsUpCarries() {
        #expect(JellyfinTimestamp.string(0.99999999) == "1970-01-01T00:00:01.0000000Z")
    }

    @Test func aNonFiniteInputDoesNotProduceGarbage() {
        #expect(JellyfinTimestamp.string(.nan) == "1970-01-01T00:00:00.0000000Z")
        #expect(JellyfinTimestamp.string(.infinity) == "1970-01-01T00:00:00.0000000Z")
    }
}

import Foundation
import Testing
@testable import Lagoon

/// The pure parts of Jellyfin's WebSocket: the envelope split, the
/// reconnection schedule, and the URL. All three are things a live socket
/// would only tell you about by misbehaving.
@Suite("Server socket")
struct ServerSocketTests {
    // MARK: - Envelope

    /// `Data` is a bare integer here, which is not a JSON object — the
    /// reason the payload is re-serialised with fragments allowed rather
    /// than decoded as a dictionary. 60 is what fixture 12.0.0 sends.
    @Test func forceKeepAliveCarriesABareInteger() throws {
        let message = try #require(envelope(#"{"MessageType":"ForceKeepAlive","Data":60}"#))
        #expect(message.messageType == "ForceKeepAlive")
        #expect(message.messageId == nil)
        #expect(try message.decodePayload(Int.self) == 60)
    }

    @Test func aCommandEnvelopeDecodesWithTheJellyfinDecoder() throws {
        let message = try #require(envelope("""
        {"MessageType":"SyncPlayCommand","Data":{"GroupId":"ea9615382d214f9c9313c26fbd3bad89",
        "PlaylistItemId":"8a3228756d3e439f9b8cd5bdbfe8deb6","When":"2026-09-14T11:44:21.3560439Z",
        "PositionTicks":0,"Command":"Unpause","EmittedAt":"2026-09-14T11:44:20.3560554Z"}}
        """))
        #expect(message.messageType == "SyncPlayCommand")

        let command = try message.decodePayload(SyncPlayCommand.self)
        #expect(command.command == .unpause)
        #expect(command.playlistItemId == "8a3228756d3e439f9b8cd5bdbfe8deb6")
        #expect(command.hasPlaylistItem)
        #expect(command.positionTicks == 0)
        // `When` is a server instant a second ahead of `EmittedAt`: the
        // group's margin for everyone to get ready.
        let when = try #require(command.whenSeconds)
        let emitted = try #require(JellyfinTimestamp.seconds(command.emittedAt))
        #expect(abs((when - emitted) - 1) < 1e-3)
    }

    /// An unknown type parses like any other and is handed on; only the
    /// caller decides it has nothing to do with it. A server that grows a
    /// message must not break the socket.
    @Test func anUnknownTypeStillParses() throws {
        let message = try #require(envelope(#"{"MessageType":"SomethingNew","MessageId":"abc","Data":{"A":1}}"#))
        #expect(message.messageType == "SomethingNew")
        #expect(message.messageId == "abc")
        #expect(message.payload != nil)
    }

    @Test func aMessageWithoutDataHasNoPayload() throws {
        let message = try #require(envelope(#"{"MessageType":"KeepAlive"}"#))
        #expect(message.payload == nil)
        #expect(throws: (any Error).self) { try message.decodePayload(Int.self) }
    }

    /// `GroupLeft` carries a bare string, and `Data: null` is not a payload.
    @Test func aBareStringPayloadSurvivesAndNullDoesNot() throws {
        let left = try #require(envelope(#"{"MessageType":"X","Data":"ea961538-2d21-4f9c-9313-c26fbd3bad89"}"#))
        #expect(try left.decodePayload(String.self) == "ea961538-2d21-4f9c-9313-c26fbd3bad89")
        #expect(try #require(envelope(#"{"MessageType":"X","Data":null}"#)).payload == nil)
    }

    @Test func malformedOrTypelessJSONIsNotAMessage() {
        #expect(envelope("{not json") == nil)
        #expect(envelope(#"{"Data":60}"#) == nil)
        #expect(envelope(#"{"MessageType":"","Data":60}"#) == nil)
        #expect(envelope("[]") == nil)
        #expect(envelope("") == nil)
    }

    // MARK: - Backoff

    @Test func theScheduleDoublesToAThirtySecondCeiling() {
        let schedule = (0..<9).map { ServerSocketBackoff.base(attempt: $0) }
        #expect(schedule == [1, 2, 4, 8, 16, 30, 30, 30, 30])
    }

    @Test func jitterStaysWithinTwentyPercentAndIsBounded() {
        #expect(abs(ServerSocketBackoff.delay(attempt: 2, jitter: 0.2) - 4.8) < 1e-9)
        #expect(abs(ServerSocketBackoff.delay(attempt: 2, jitter: -0.2) - 3.2) < 1e-9)
        // A caller that passes nonsense still gets a sane delay.
        #expect(abs(ServerSocketBackoff.delay(attempt: 2, jitter: 5) - 4.8) < 1e-9)
        for attempt in 0..<10 {
            let delay = ServerSocketBackoff.randomDelay(attempt: attempt)
            let base = ServerSocketBackoff.base(attempt: attempt)
            #expect(delay >= base * 0.8 - 1e-9)
            #expect(delay <= base * 1.2 + 1e-9)
        }
    }

    // MARK: - URL

    /// The socket is built from `serverRelativeURL("socket")`, so a
    /// reverse-proxy base path has to survive the scheme swap — the exact
    /// thing that broke every transcode on a base-path server.
    @Test func theSocketURLSwapsTheSchemeAndKeepsTheBasePath() throws {
        let base = try #require(URL(string: "https://media.example/jellyfin/socket"))
        let url = try #require(ServerSocketURL.socket(from: base, token: "tok en", deviceId: "device-1"))
        #expect(url.scheme == "wss")
        #expect(url.path == "/jellyfin/socket")
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.first(where: { $0.name == "api_key" })?.value == "tok en")
        #expect(components.queryItems?.first(where: { $0.name == "deviceId" })?.value == "device-1")
    }

    @Test func plainHTTPBecomesWSAndAnUnknownSchemeIsRefused() throws {
        let base = try #require(URL(string: "http://192.168.1.173:8096/socket"))
        let url = try #require(ServerSocketURL.socket(from: base, token: "t", deviceId: "d"))
        #expect(url.scheme == "ws")
        #expect(url.port == 8096)
        #expect(ServerSocketURL.socket(
            from: URL(string: "ftp://media.example/socket")!,
            token: "t",
            deviceId: "d"
        ) == nil)
    }

    private func envelope(_ json: String) -> ServerSocketMessage? {
        ServerSocketEnvelope.parse(Data(json.utf8))
    }
}

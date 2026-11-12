import Foundation
import LagoonEngine
import Testing
@testable import Lagoon

/// The player's own previous and next buttons, and its sound button.
@Suite("Player episode and sound buttons")
struct PlayerEpisodeButtonsTests {
    private func item(_ id: String, type: String = "Movie") throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"}"#.utf8))
    }

    private func queue(_ ids: [String], position: Int) throws -> PlayQueue {
        let entries = try ids.map { PlayQueueList.Entry(media: try item($0)) }
        return .list(try #require(PlayQueueList(entries: entries, position: position)))
    }

    @Test func aSeriesQueueAsksTheServerBeforeAnEpisodeOnly() throws {
        #expect(PlayQueue.series.predecessor(before: try item("e2", type: "Episode")) == .previousEpisode)
        #expect(PlayQueue.series.predecessor(before: try item("m1")) == .none)
    }

    @Test func aListQueueStepsBackToItsPreviousEntry() throws {
        let middle = try queue(["a", "b", "c"], position: 1)
        #expect(middle.predecessor(before: try item("b")) == .entry(try item("a")))
        let first = middle.retreated()
        #expect(first == (try queue(["a", "b", "c"], position: 0)))
        #expect(first.predecessor(before: try item("a")) == .none)
        // Stepping back past the start goes nowhere.
        #expect(first.retreated() == first)
        // Back then forward is where it started.
        #expect(first.advanced() == middle)
    }

    /// `AdjacentTo` answers [before, this, after], or less at either end.
    @Test func thePreviousEpisodeIsTheOneBeforeTheAnchor() throws {
        let items = [try item("e1"), try item("e2"), try item("e3")]
        #expect(JellyfinClient.item(before: "e2", in: items)?.id == "e1")
        #expect(JellyfinClient.item(before: "e1", in: items) == nil)
        // A missing anchor is no answer, not the first item.
        #expect(JellyfinClient.item(before: "e9", in: items) == nil)
    }

    @Test @MainActor func thePreviousEpisodeComesFromTheSeriesNeighbours() async throws {
        let host = "previous-episode.test"
        StubURLProtocol.register(host: host) { _ in
            (200, ["Content-Type": "application/json"], Data(#"{"Items":[{"Id":"e1","Name":"e1","Type":"Episode","SeriesId":"s"},{"Id":"e2","Name":"e2","Type":"Episode","SeriesId":"s"},{"Id":"e3","Name":"e3","Type":"Episode","SeriesId":"s"}]}"#.utf8))
        }
        defer { StubURLProtocol.unregister(host: host) }
        let client = StubURLProtocol.makeJellyfinClient(host: host, deviceId: "previous-episode-tests")
        let episode = try JellyfinClient.decoder.decode(
            MediaItem.self,
            from: Data(#"{"Id":"e2","Name":"e2","Type":"Episode","SeriesId":"s"}"#.utf8)
        )

        let previous = try await client.episodeBefore(episode)

        #expect(previous?.id == "e1")
        let request = try #require(StubURLProtocol.requests(host: host).first?.url)
        #expect(request.path.hasSuffix("Shows/s/Episodes"))
        let query = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(query.contains(URLQueryItem(name: "AdjacentTo", value: "e2")))
    }

    @Test func theButtonsShowOnlyWithANeighbourAndOutsideAGroup() {
        #expect(PlayerEpisodeButtons.offered(hasPrevious: false, hasNext: false, inGroup: false) == nil)
        #expect(PlayerEpisodeButtons.offered(hasPrevious: true, hasNext: false, inGroup: false)
            == PlayerEpisodeButtons(hasPrevious: true, hasNext: false))
        #expect(PlayerEpisodeButtons.offered(hasPrevious: false, hasNext: true, inGroup: false)
            == PlayerEpisodeButtons(hasPrevious: false, hasNext: true))
        // In Watch Together the group changes the item.
        #expect(PlayerEpisodeButtons.offered(hasPrevious: true, hasNext: true, inGroup: true) == nil)
    }

    @Test func theSoundButtonShowsTheEnginesChannelLimit() {
        for limit in AudioChannelLimit.allCases {
            #expect(AudioChannelLimit(engineLimit: limit.engineLimit) == limit)
        }
        let options = PlayerSoundOptions(
            shaping: AudioShaping(nightMode: false, dialogueBoost: false, channelLimit: .stereo),
            setNightMode: { _ in },
            setDialogueBoost: { _ in },
            setChannelLimit: { _ in }
        )
        #expect(options.channelLimit == .stereo)
    }
}

import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// What the player rolls into next: the server's next episode, or a list
/// queue's next entry.
@Suite("Play queue")
struct PlayQueueTests {
    private func item(_ id: String, type: String = "Movie", extra: String = "") throws -> MediaItem {
        try JellyfinClient.decoder.decode(MediaItem.self, from: Data(#"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"\#(extra)}"#.utf8))
    }

    private func list(_ ids: [String], position: Int = 0) throws -> PlayQueueList {
        let entries = try ids.enumerated().map { index, id in
            PlayQueueList.Entry(media: try item(id), playlistItemId: "p\(index)")
        }
        return try #require(PlayQueueList(entries: entries, position: position))
    }

    @Test func aSeriesQueueAsksTheServerAfterAnEpisodeOnly() throws {
        #expect(PlayQueue.series.successor(after: try item("e1", type: "Episode")) == .nextEpisode)
        // A lone movie plays on its own, as it always has.
        #expect(PlayQueue.series.successor(after: try item("m1")) == .none)
    }

    @Test func aListQueuePlaysItsNextEntryWhateverItsType() throws {
        let playlist = try PlayQueueList(
            entries: [
                .init(media: try item("m1")),
                .init(media: try item("e1", type: "Episode")),
                .init(media: try item("m2")),
            ]
        ).map(PlayQueue.list)
        let queue = try #require(playlist)

        #expect(queue.successor(after: try item("m1")) == .entry(try item("e1", type: "Episode")))
        let second = queue.advanced()
        #expect(second.successor(after: try item("e1", type: "Episode")) == .entry(try item("m2")))
        let last = second.advanced()
        #expect(last.successor(after: try item("m2")) == .none)
        // Advancing past the end goes nowhere.
        #expect(last.advanced() == last)
    }

    @Test func aRepeatedTitleIsPlayedTwice() throws {
        // The MCU in timeline order can list a title twice; the position,
        // not the title, says which one is playing.
        var queue = PlayQueue.list(try list(["a", "b", "a", "c"]))
        var played: [String] = []
        var current = try item("a")
        played.append(current.id)
        // Bounded: a queue that finds its place by title loops a↔b forever.
        while played.count < 8, case .entry(let next) = queue.successor(after: current) {
            queue = queue.advanced()
            current = next
            played.append(current.id)
        }
        #expect(played == ["a", "b", "a", "c"])
        guard case .list(let finished) = queue else { Issue.record("not a list"); return }
        #expect(finished.position == 3)
        #expect(finished.current.playlistItemId == "p3")
    }

    @Test func aListCanStartPartWayThrough() throws {
        let queue = try list(["a", "b", "c"], position: 1)
        #expect(queue.current.media.id == "b")
        #expect(queue.next?.media.id == "c")
        #expect(PlayQueueList(entries: queue.entries, position: 3) == nil)
        #expect(PlayQueueList(entries: [], position: 0) == nil)
    }

    @Test func aSeriesQueueDoesNotMove() {
        #expect(PlayQueue.series.advanced() == .series)
    }

    @Test func onlyAListHoldsTheCountdownForTheEnd() throws {
        #expect(!PlayQueue.series.countdownWaitsForEnd)
        #expect(PlayQueue.list(try list(["a"])).countdownWaitsForEnd)
    }

    // MARK: - The card

    @Test func aMovieReadsAsItsTitleAndYear() throws {
        let movie = try item("Iron Man", extra: #","ProductionYear":2008"#)
        let card = NextUpEpisode(movie, imageURL: nil)
        #expect(card.title == "Iron Man")
        #expect(card.subtitle == "2008")
    }

    @Test func anEpisodeKeepsItsEpisodeLabel() throws {
        let episode = try item("Pilot", type: "Episode", extra: #","ParentIndexNumber":1,"IndexNumber":1,"ProductionYear":2004"#)
        let card = NextUpEpisode(episode, imageURL: nil)
        #expect(card.title == "Pilot")
        #expect(card.subtitle == episode.episodeLabel)
        #expect(card.subtitle != "2004")
    }
}

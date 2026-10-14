import Foundation
import Testing
@testable import Lagoon

/// Where the viewer is in a collection or playlist: what is stored on the
/// server, and what Home makes of it.
@Suite("Queue progress")
@MainActor
struct QueueProgressTests {
    private let cars = QueueSource(id: "cars", kind: .collection, name: "Cars Collection", displayOrder: "PremiereDate")

    private func item(
        _ id: String,
        type: String = "Movie",
        played: Bool = false,
        percent: Double? = nil,
        lastPlayed: String? = nil,
        seriesId: String? = nil
    ) throws -> MediaItem {
        var userData = #""Played":\#(played)"#
        if let percent { userData += #","PlayedPercentage":\#(percent)"# }
        if let lastPlayed { userData += #","LastPlayedDate":"\#(lastPlayed)""# }
        let series = seriesId.map { #","SeriesId":"\#($0)""# } ?? ""
        let json = #"{"Id":"\#(id)","Name":"\#(id)","Type":"\#(type)"\#(series),"UserData":{\#(userData)}}"#
        return try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    private func entry(position: Int, itemId: String) -> QueueProgressEntry {
        QueueProgressEntry(source: cars, position: position, itemId: itemId)
    }

    // MARK: - The stored record

    @Test func writingKeepsEveryOtherPreferenceExactly() throws {
        // Jellyfin resets skip lengths and the overlay setting when a write
        // leaves them out, so they must go back untouched.
        let stored: [String: Any] = [
            "Id": "2234c1aa", "SortBy": "SortName", "Client": "Lagoon", "ShowBackdrop": true,
            "CustomPrefs": ["skipForwardLength": "30000", "skipBackLength": "10000", "tvhome": NSNull()],
        ]
        let written = try QueueProgressRecord.preferences(stored, storing: [entry(position: 1, itemId: "cars2")])
        let custom = try #require(written["CustomPrefs"] as? [String: Any])
        #expect(custom["skipForwardLength"] as? String == "30000")
        #expect(custom["skipBackLength"] as? String == "10000")
        #expect(custom["tvhome"] is NSNull)
        #expect(written["SortBy"] as? String == "SortName")
        #expect(written["ShowBackdrop"] as? Bool == true)
        #expect(written["Id"] as? String == QueueProgressRecord.preferencesID)
        #expect(QueueProgressRecord.entries(in: custom) == [entry(position: 1, itemId: "cars2")])
    }

    @Test func theLatestListComesFirstAndReplacesItsOlderPlace() {
        let older = QueueProgressEntry(source: QueueSource(id: "mcu", kind: .playlist, name: "MCU"), position: 3, itemId: "x")
        var entries = QueueProgressRecord.recording(entry(position: 0, itemId: "cars"), in: [])
        entries = QueueProgressRecord.recording(older, in: entries)
        entries = QueueProgressRecord.recording(entry(position: 1, itemId: "cars2"), in: entries)
        #expect(entries.map(\.source.id) == ["cars", "mcu"])
        #expect(entries.first?.position == 1)
    }

    @Test func theRecordKeepsTenLists() {
        var entries: [QueueProgressEntry] = []
        for index in 0..<12 {
            let source = QueueSource(id: "list\(index)", kind: .collection, name: "List \(index)")
            entries = QueueProgressRecord.recording(QueueProgressEntry(source: source, position: 0, itemId: "a"), in: entries)
        }
        #expect(entries.count == QueueProgressRecord.maximumEntries)
        #expect(entries.first?.source.id == "list11")
    }

    @Test func aMissingOrDamagedRecordReadsAsEmpty() {
        #expect(QueueProgressRecord.entries(in: [:]).isEmpty)
        #expect(QueueProgressRecord.entries(in: [QueueProgressRecord.key: "not json"]).isEmpty)
    }

    @Test func aQueueReportsItsPlaceAsItMovesOn() throws {
        let list = try #require(PlayQueueList(
            entries: [try item("cars"), try item("cars2")].map { PlayQueueList.Entry(media: $0) },
            source: cars
        ))
        #expect(list.progress == entry(position: 0, itemId: "cars"))
        #expect(list.advanced()?.progress == entry(position: 1, itemId: "cars2"))
    }

    // MARK: - What Home shows

    @Test func aPartWatchedTitleKeepsItsCardWithTheListsLabel() throws {
        let items = [try item("cars", played: true), try item("cars2", percent: 40), try item("cars3")]
        guard case .inProgress(let context) = QueueProgressResolver.resolve(entry(position: 1, itemId: "cars2"), items: items) else {
            Issue.record("expected in progress"); return
        }
        #expect(context.title.id == "cars2")
        #expect(context.label == "Cars Collection · 2 of 3")
        #expect(context.list.next?.media.id == "cars3")
        #expect(context.list.source == cars)
    }

    @Test func aFinishedTitleOffersTheNextOne() throws {
        let items = [try item("cars", played: true, lastPlayed: "2026-10-14T16:12:03.1234567Z"), try item("cars2"), try item("cars3")]
        guard case .upNext(let context, let lastPlayed) = QueueProgressResolver.resolve(entry(position: 0, itemId: "cars"), items: items) else {
            Issue.record("expected up next"); return
        }
        #expect(context.title.id == "cars2")
        #expect(context.label == "Cars Collection · 2 of 3")
        #expect(lastPlayed == "2026-10-14T16:12:03.1234567Z")
    }

    @Test func aTitleBarelyStartedIsStillNext() throws {
        let items = [try item("cars"), try item("cars2")]
        guard case .upNext(let context, _) = QueueProgressResolver.resolve(entry(position: 0, itemId: "cars"), items: items) else {
            Issue.record("expected up next"); return
        }
        #expect(context.title.id == "cars")
    }

    @Test func theLastTitleWatchedFinishesTheList() throws {
        let items = [try item("cars", played: true), try item("cars2", played: true)]
        #expect(QueueProgressResolver.resolve(entry(position: 1, itemId: "cars2"), items: items) == .finished)
    }

    @Test func aListThatMovedItsTitleIsFollowedAndOneThatDroppedItIsForgotten() throws {
        let reordered = [try item("cars3"), try item("cars", played: true), try item("cars2")]
        guard case .upNext(let context, _) = QueueProgressResolver.resolve(entry(position: 0, itemId: "cars"), items: reordered) else {
            Issue.record("expected up next"); return
        }
        #expect(context.title.id == "cars2")
        #expect(QueueProgressResolver.resolve(entry(position: 0, itemId: "gone"), items: reordered) == .finished)
    }

    @Test func nextUpMixesListsAndShowsByWhenEachWasLastWatched() throws {
        let showA = try item("a1", type: "Episode", seriesId: "a")
        let showB = try item("b1", type: "Episode", seriesId: "b")
        let untimed = try item("c1", type: "Episode", seriesId: "c")
        let merged = QueueProgressResolver.mergedNextUp(
            server: [showA, showB, untimed],
            seriesLastPlayed: ["a": "2026-10-10T10:00:00Z", "b": "2026-10-12T10:00:00Z"],
            queued: [(try item("cars2"), "2026-10-11T10:00:00.5Z")]
        )
        #expect(merged.map(\.id) == ["b1", "cars2", "a1", "c1"])
    }

    @Test func aTitleBothNextInAListAndOnTheServerAppearsOnce() throws {
        let episode = try item("e1", type: "Episode", seriesId: "s")
        let merged = QueueProgressResolver.mergedNextUp(
            server: [episode],
            seriesLastPlayed: [:],
            queued: [(episode, "2026-10-11T10:00:00Z")]
        )
        #expect(merged.map(\.id) == ["e1"])
    }

    @Test func withoutListsTheServersOrderStands() throws {
        let server = [try item("b1", type: "Episode", seriesId: "b"), try item("a1", type: "Episode", seriesId: "a")]
        let merged = QueueProgressResolver.mergedNextUp(server: server, seriesLastPlayed: ["a": "2026-10-12T10:00:00Z"], queued: [])
        #expect(merged.map(\.id) == ["b1", "a1"])
    }
}

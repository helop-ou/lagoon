import Foundation
import Testing
@testable import Lagoon

@Suite("Episode labels")
struct EpisodeLabelTests {
    @Test func labelsNameSeasonsDoubleEpisodesAndSpecials() {
        #expect(EpisodeLabel.text(season: 1, episode: 3, episodeEnd: nil) == "S1 E3")
        #expect(EpisodeLabel.text(season: 14, episode: 1, episodeEnd: 2) == "S14 E1–2")
        #expect(EpisodeLabel.text(season: nil, episode: 4, episodeEnd: 5) == "E4–5")
        #expect(EpisodeLabel.text(season: 0, episode: 2, episodeEnd: nil) == "Special 2")
        #expect(EpisodeLabel.text(season: 0, episode: 1, episodeEnd: 2) == "Special 1–2")
        #expect(EpisodeLabel.text(season: 0, episode: nil, episodeEnd: nil) == "Special")
        // An end that is no later than the start is noise, not a range.
        #expect(EpisodeLabel.text(season: 1, episode: 3, episodeEnd: 3) == "S1 E3")
        #expect(EpisodeLabel.text(season: 1, episode: nil, episodeEnd: nil) == nil)
    }

    /// A season's episodes with "display specials within seasons" on: the
    /// server places the special by `AirsBeforeSeasonNumber` and keeps its
    /// season number at 0.
    @Test func aSeasonKeepsTheServersOrderAndLabelsItsSpecialInPlace() throws {
        let json = #"""
        {"Items":[
          {"Id":"e1","Type":"Episode","Name":"Pilot","ParentIndexNumber":2,"IndexNumber":1,"IndexNumberEnd":2,"SeriesName":"Show"},
          {"Id":"s1","Type":"Episode","Name":"Holiday","ParentIndexNumber":0,"IndexNumber":1,"AirsBeforeSeasonNumber":2,"AirsBeforeEpisodeNumber":3,"SeriesName":"Show"},
          {"Id":"e3","Type":"Episode","Name":"Return","ParentIndexNumber":2,"IndexNumber":3,"SeriesName":"Show"}
        ],"TotalRecordCount":3}
        """#
        let page = try JellyfinClient.decoder.decode(ItemsPage.self, from: Data(json.utf8))

        #expect(page.items.map(\.id) == ["e1", "s1", "e3"])
        #expect(page.items.map(\.episodeLabel) == ["S2 E1–2", "Special 1", "S2 E3"])
        #expect(page.items[1].railSubtitle == "Special 1 · Holiday")
        #expect(page.items[0].railTitle == "Show")
    }

    /// A download names an episode exactly as the item it came from, even
    /// when the server sent no season or no episode number.
    @Test(arguments: [
        #"{"Id":"e1","Type":"Episode","ParentIndexNumber":0,"IndexNumber":3,"IndexNumberEnd":4}"#,
        #"{"Id":"e1","Type":"Episode","IndexNumber":4}"#,
        #"{"Id":"e1","Type":"Episode","ParentIndexNumber":0}"#,
        #"{"Id":"e1","Type":"Episode","ParentIndexNumber":2}"#,
    ])
    func downloadsLabelLikeTheirSource(json: String) throws {
        let item = try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
        let entry = DownloadEntry(
            itemID: item.id, type: .episode, title: "Special",
            seriesID: "show", seriesName: "Show",
            seasonNumber: item.parentIndexNumber, episodeNumber: item.indexNumber,
            episodeNumberEnd: item.indexNumberEnd,
            productionYear: nil, runTimeTicks: nil,
            requestedQuality: .original, quality: .original, fileName: "e1.mkv",
            mediaSourceID: "source1", eTag: nil, createdAt: nil
        )
        #expect(entry.episodeLabel == item.episodeLabel)
    }

    @Test func aDownloadedDoubleSpecialIsLabelledAsOne() throws {
        let entry = DownloadEntry(
            itemID: "e1", type: .episode, title: "Special",
            seriesID: "show", seriesName: "Show",
            seasonNumber: 0, episodeNumber: 3, episodeNumberEnd: 4,
            productionYear: nil, runTimeTicks: nil,
            requestedQuality: .original, quality: .original, fileName: "e1.mkv",
            mediaSourceID: "source1", eTag: nil, createdAt: nil
        )
        #expect(entry.episodeLabel == "Special 3–4")
    }

    @Test func aManifestFromBeforeDoubleEpisodesStillDecodes() throws {
        let json = #"""
        {"itemID":"e1","type":"Episode","title":"Pilot","seasonNumber":1,"episodeNumber":1,
         "quality":"original","fileName":"e1.mkv","mediaSourceID":"s","receivedBytes":0,"state":"complete","artworkFiles":{}}
        """#
        let entry = try JSONDecoder().decode(DownloadEntry.self, from: Data(json.utf8))
        #expect(entry.episodeNumberEnd == nil)
        #expect(entry.episodeLabel == "S1 E1")
    }
}

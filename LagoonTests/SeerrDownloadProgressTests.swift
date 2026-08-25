import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr download progress")
struct SeerrDownloadProgressTests {
    private func item(
        id: String,
        size: Int64,
        left: Int64,
        status: String = "downloading",
        timeLeft: String? = "00:10:00"
    ) throws -> SeerrDownloadItem {
        let time = timeLeft.map { "\"timeLeft\":\"\($0)\"," } ?? ""
        let json = """
        {"downloadId":"\(id)","title":"Something.1080p","status":"\(status)",
         \(time)"size":\(size),"sizeLeft":\(left)}
        """
        return try JSONDecoder().decode(SeerrDownloadItem.self, from: Data(json.utf8))
    }

    @Test @MainActor func progressIsHowMuchHasArrived() throws {
        let progress = SeerrDownloadProgress(items: [try item(id: "a", size: 1000, left: 250)])
        #expect(progress?.fraction == 0.75)
        #expect(progress?.percentText == "75%")
    }

    /// The trap, taken from the live server: a season pack is one download
    /// that Sonarr reports once per episode, each row carrying the pack's
    /// full size. Ten rows of 7.15 GB are one 7.15 GB download, not 71 GB.
    @Test @MainActor func aSeasonPackReportedPerEpisodeCountsOnce() throws {
        let size: Int64 = 7_154_124_710
        let rows = try (0..<10).map { _ in
            try item(id: "b13acbc2f85a48798499f5f79a024620", size: size, left: size / 2)
        }
        let progress = try #require(SeerrDownloadProgress(items: rows))
        #expect(progress.downloadCount == 1, "ten episode rows are one download")
        #expect(progress.fraction == 0.5)
    }

    @Test @MainActor func genuinelySeparateDownloadsAreAggregated() throws {
        let progress = try #require(SeerrDownloadProgress(items: [
            try item(id: "a", size: 1000, left: 0),
            try item(id: "b", size: 1000, left: 1000),
        ]))
        #expect(progress.downloadCount == 2)
        #expect(progress.fraction == 0.5)
    }

    /// Also seen live: every row complete with `sizeLeft: 0` while the media
    /// is still PROCESSING — the download finished and Sonarr is importing.
    /// Sitting at "100%" with no explanation reads as stuck.
    @Test @MainActor func aFinishedDownloadSaysItIsImporting() throws {
        let progress = try #require(SeerrDownloadProgress(items: [
            try item(id: "a", size: 500, left: 0, status: "completed", timeLeft: "00:00:00"),
        ]))
        #expect(progress.isImporting)
        #expect(progress.fraction == 1)
        #expect(progress.summary == "Downloaded, adding to your library")
    }

    @Test @MainActor func aRunningDownloadQuotesItsTimeLeft() throws {
        let progress = try #require(SeerrDownloadProgress(items: [
            try item(id: "a", size: 1000, left: 400, timeLeft: "00:12:34"),
        ]))
        #expect(!progress.isImporting)
        #expect(progress.timeLeft == "00:12:34")
        #expect(progress.summary.contains("60%"))
        #expect(progress.summary.contains("00:12:34"))
    }

    /// A finished row reports "00:00:00"; quoting that as the time remaining
    /// would be worse than saying nothing.
    @Test @MainActor func aFinishedRowsZeroTimeIsNotQuoted() throws {
        let progress = try #require(SeerrDownloadProgress(items: [
            try item(id: "a", size: 1000, left: 500, timeLeft: "00:05:00"),
            try item(id: "b", size: 1000, left: 0, status: "completed", timeLeft: "00:00:00"),
        ]))
        #expect(progress.timeLeft == "00:05:00")
    }

    @Test @MainActor func anEmptyQueueIsNoProgressAtAll() {
        #expect(SeerrDownloadProgress(items: []) == nil)
    }

    /// A zero size must not divide by zero or claim completion.
    @Test @MainActor func anUnknownSizeReportsNothingRatherThanCrashing() throws {
        let progress = try #require(SeerrDownloadProgress(items: [try item(id: "a", size: 0, left: 0)]))
        #expect(progress.fraction == 0)
        #expect(progress.percentText == "0%")
    }

    /// Rows without an id cannot be deduplicated, and dropping them would
    /// hide the only thing happening.
    @Test @MainActor func rowsWithoutAnIdAreKept() throws {
        let progress = try #require(SeerrDownloadProgress(items: [
            try item(id: "", size: 100, left: 50),
            try item(id: "", size: 100, left: 50),
        ]))
        #expect(progress.downloadCount == 2)
    }

    // MARK: - Through a request

    /// 4K requests read the 4K queue, the same split as availability.
    @Test @MainActor func aFourKRequestReadsTheFourKQueue() throws {
        let json = """
        {"id":1,"status":2,"is4k":true,"type":"movie","media":{"id":1,"tmdbId":603,
         "mediaType":"movie","status":3,"status4k":3,
         "downloadStatus":[{"downloadId":"hd","title":"t","status":"downloading","size":100,"sizeLeft":0}],
         "downloadStatus4k":[{"downloadId":"uhd","title":"t","status":"downloading","size":100,"sizeLeft":75}]}}
        """
        let request = try JSONDecoder().decode(SeerrMediaRequest.self, from: Data(json.utf8))
        #expect(request.progress == .processing)
        #expect(request.downloadProgress?.fraction == 0.25)
    }

    /// Every response Lagoon already reads carries these keys, but an older
    /// server or a media row with nothing queued must decode cleanly.
    @Test @MainActor func aRequestWithNoQueueHasNoProgress() throws {
        let request = try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(#"{"id":1,"status":2,"type":"movie","media":{"id":1,"status":3}}"#.utf8)
        )
        #expect(request.downloadProgress == nil)
        #expect(request.progress == .processing)
    }
}

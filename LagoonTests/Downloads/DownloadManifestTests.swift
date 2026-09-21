import Foundation
import Testing
@testable import Lagoon

/// Pure state-machine coverage for offline downloads: no session,
/// no disk, no clock beyond what a test hands in.
@Suite("Download manifest")
struct DownloadManifestTests {
    static func makeEntry(id: String = "item1", quality: DownloadQuality = .original) -> DownloadEntry {
        DownloadEntry(
            itemID: id, type: .movie, title: "Title \(id)",
            seriesID: nil, seriesName: nil, seasonNumber: nil, episodeNumber: nil,
            productionYear: 2024, runTimeTicks: Ticks.ticks(3_600),
            requestedQuality: quality, quality: quality, fileName: "\(id).mp4",
            mediaSourceID: "source1", eTag: nil, createdAt: Date()
        )
    }

    @Test func startProgressComplete() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())

        manifest.markStarted("item1", taskIdentifier: 7, attemptToken: "token1")
        #expect(manifest.entry(for: "item1")?.state == .downloading)
        #expect(manifest.entry(for: "item1")?.taskIdentifier == 7)
        #expect(manifest.entry(for: "item1")?.attemptToken == "token1")

        manifest.recordProgress("item1", received: 500, expected: 1_000)
        #expect(manifest.entry(for: "item1")?.receivedBytes == 500)
        #expect(manifest.entry(for: "item1")?.fractionComplete == 0.5)

        manifest.markComplete("item1", bytes: 1_000, at: Date())
        let entry = manifest.entry(for: "item1")
        #expect(entry?.isComplete == true)
        #expect(entry?.taskIdentifier == nil)
        #expect(entry?.expectedBytes == 1_000)
    }

    @Test func pauseKeepsResumeFile() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 1, attemptToken: "token1")

        manifest.markPaused("item1", resumeDataFile: "item1.resume")
        let entry = manifest.entry(for: "item1")
        #expect(entry?.state == .paused)
        #expect(entry?.resumeDataFile == "item1.resume")
        #expect(entry?.taskIdentifier == nil)
    }

    @Test func pauseClearsAStaleFailureString() {
        // A late progress or failure callback for the attempt being paused
        // must not leave old error text sitting under a fresh pause.
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 1, attemptToken: "token1")
        manifest.markFailed("item1", reason: "Connection lost", resumeDataFile: nil)

        manifest.markPaused("item1", resumeDataFile: nil)
        #expect(manifest.entry(for: "item1")?.failure == nil)
    }

    @Test func failureAfterPauseStaysPaused() {
        // A cancel's own didCompleteWithError callback can still land after
        // the pause it caused has already been applied; it must not flip a
        // deliberate pause into a failure.
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 1, attemptToken: "token1")
        manifest.markPaused("item1", resumeDataFile: "item1.resume")

        manifest.markFailed("item1", reason: "cancelled", resumeDataFile: "item1.resume")
        #expect(manifest.entry(for: "item1")?.state == .paused)
    }

    @Test func latePauseAndFailureCannotUndoCompletion() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 1, attemptToken: "token1")
        manifest.markComplete("item1", bytes: 500, at: Date())
        manifest.markPaused("item1", resumeDataFile: "stale.resume")
        manifest.markFailed("item1", reason: "Connection lost", resumeDataFile: nil)
        #expect(manifest.entry(for: "item1")?.state == .complete)
        #expect(manifest.entry(for: "item1")?.failure == nil)
        #expect(manifest.entry(for: "item1")?.resumeDataFile == nil)
        #expect(manifest.entry(for: "item1")?.receivedBytes == 500)
    }

    @Test func lateProgressCannotRestartAFailedTransfer() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry())
        manifest.markStarted("item1", taskIdentifier: 1, attemptToken: "token1")
        manifest.markFailed("item1", reason: "Connection lost", resumeDataFile: nil)
        manifest.recordProgress("item1", received: 500, expected: 1_000)
        #expect(manifest.entry(for: "item1")?.state == .failed)
        #expect(manifest.entry(for: "item1")?.receivedBytes == 0)
    }

    @Test func recordProgressIsANoOpOncePausedOrComplete() {
        // A progress callback queued before a pause (or a delete-and-restart
        // that finishes fast) can still land after the state moved on; it
        // must not resurrect a byte count or un-pause the entry.
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "paused"))
        manifest.markStarted("paused", taskIdentifier: 1, attemptToken: "token1")
        manifest.markPaused("paused", resumeDataFile: "paused.resume")
        manifest.recordProgress("paused", received: 999, expected: 1_000)
        #expect(manifest.entry(for: "paused")?.state == .paused)
        #expect(manifest.entry(for: "paused")?.receivedBytes == 0)

        manifest.insert(Self.makeEntry(id: "done"))
        manifest.markStarted("done", taskIdentifier: 2, attemptToken: "token2")
        manifest.markComplete("done", bytes: 1_000, at: Date())
        manifest.recordProgress("done", received: 1, expected: 1_000)
        #expect(manifest.entry(for: "done")?.state == .complete)
        #expect(manifest.entry(for: "done")?.receivedBytes == 1_000)
    }

    @Test func reconcileReAdoptsLiveTasksAndDemotesLostOnes() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "live"))
        manifest.markStarted("live", taskIdentifier: 1, attemptToken: "token1")
        manifest.insert(Self.makeEntry(id: "lostWithResume"))
        manifest.markStarted("lostWithResume", taskIdentifier: 2, attemptToken: "token2")
        manifest.update("lostWithResume") { $0.resumeDataFile = "lostWithResume.resume" }
        manifest.insert(Self.makeEntry(id: "lostNoResume"))
        manifest.markStarted("lostNoResume", taskIdentifier: 3, attemptToken: "token3")

        let lost = manifest.reconcile(liveTasks: ["live": 99])
        #expect(Set(lost) == Set(["lostWithResume", "lostNoResume"]))
        #expect(manifest.entry(for: "live")?.taskIdentifier == 99)
        #expect(manifest.entry(for: "live")?.state == .downloading)
        #expect(manifest.entry(for: "lostWithResume")?.state == .paused)
        #expect(manifest.entry(for: "lostWithResume")?.taskIdentifier == nil)
        #expect(manifest.entry(for: "lostNoResume")?.state == .failed)
    }

    @Test func reconcileDoesNotDemoteAttemptsStartedDuringTaskLookup() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "restarted"))
        manifest.markStarted("restarted", taskIdentifier: 10, attemptToken: "new")
        manifest.insert(Self.makeEntry(id: "newItem"))
        manifest.markStarted("newItem", taskIdentifier: 11, attemptToken: "first")
        let lost = manifest.reconcile(liveTasks: [:], queriedAttempts: ["restarted": "old"])
        #expect(lost.isEmpty)
        #expect(manifest.entry(for: "restarted")?.taskIdentifier == 10)
        #expect(manifest.entry(for: "newItem")?.state == .downloading)
    }

    @Test func reconcilePromotesAFinishedFileToComplete() {
        // A `didFinishDownloadingTo` that landed while the process was dead
        // wrote the file and the manifest, but the process only sees the
        // task gone when it comes back; the file on disk still says the
        // transfer actually finished, so it must not be declared lost.
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "finishedOffline"))
        manifest.markStarted("finishedOffline", taskIdentifier: 1, attemptToken: "token1")

        let lost = manifest.reconcile(liveTasks: [:], completedFiles: ["finishedOffline": 12_345])
        #expect(lost.isEmpty)
        let entry = manifest.entry(for: "finishedOffline")
        #expect(entry?.state == .complete)
        #expect(entry?.receivedBytes == 12_345)
        #expect(entry?.expectedBytes == 12_345)
    }

    @Test func insertReplacesAnEarlierEntryForTheSameItem() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "item1", quality: .standard))
        manifest.insert(Self.makeEntry(id: "item1", quality: .high))
        #expect(manifest.entries.count == 1)
        #expect(manifest.entry(for: "item1")?.quality == .high)
    }

    @Test func storageUsedSumsReceivedBytesAcrossEntries() {
        var manifest = DownloadManifest()
        manifest.insert(Self.makeEntry(id: "a"))
        manifest.update("a") { $0.receivedBytes = 100 }
        manifest.insert(Self.makeEntry(id: "b"))
        manifest.update("b") { $0.receivedBytes = 250 }
        #expect(manifest.storageUsed == 350)
    }

    @Test func onePendingReportPerItemNewestWins() {
        var manifest = DownloadManifest()
        manifest.enqueue(PendingPlaybackReport(itemID: "item1", mediaSourceID: "source1", positionTicks: 100, createdAt: Date()))
        manifest.enqueue(PendingPlaybackReport(itemID: "item1", mediaSourceID: "source1", positionTicks: 500, createdAt: Date()))
        #expect(manifest.pendingReports.count == 1)
        #expect(manifest.pendingReports.first?.positionTicks == 500)
    }

    @Test func resumesFromStartIsTrueOnlyForATranscode() {
        #expect(Self.makeEntry(quality: .original).resumesFromStart == false)
        #expect(Self.makeEntry(quality: .high).resumesFromStart == true)
        #expect(Self.makeEntry(quality: .standard).resumesFromStart == true)
    }

    @Test func attemptTokenDecodesAsNilFromAManifestSavedBeforeItExisted() throws {
        // `attemptToken` postdates the first
        // shipped manifest schema; a file written before it must still
        // decode, with the field simply absent.
        let json = """
        {"entries":[{"itemID":"item1","type":"Movie","title":"Old Entry",
        "runTimeTicks":36000000000,"requestedQuality":"original","quality":"original",
        "fileName":"item1.mp4","mediaSourceID":"source1","receivedBytes":0,"state":"queued",
        "artworkFiles":{},"createdAt":"2024-01-01T00:00:00Z"}],"pendingReports":[]}
        """
        // `DownloadStore` itself is iOS only; decoding directly here keeps
        // this test running on every platform the manifest type does.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(DownloadManifest.self, from: Data(json.utf8))
        #expect(manifest.entry(for: "item1")?.attemptToken == nil)
    }
}

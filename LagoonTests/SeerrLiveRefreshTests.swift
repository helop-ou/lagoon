import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr live detail refresh")
struct SeerrLiveRefreshTests {
    @Test func approvalAndTransferCadencesAreDeliberatelyDifferent() {
        #expect(SeerrLiveRefreshCadence.waitingForApproval.interval() == .seconds(30))
        #expect(SeerrLiveRefreshCadence.transferring.interval() == .seconds(10))
    }

    @Test func debugCadenceCanRunWithoutAProductionLengthWait() {
        let suite = "SeerrLiveRefreshTests"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(0.05, forKey: "debug.seerrLiveRefreshIntervalSeconds")
        #expect(
            SeerrLiveRefreshCadence.transferring.interval(defaults: defaults)
                == .seconds(0.05)
        )
    }

    @Test func requestDetailsPollOnlyWhileTheirStateCanStillChange() throws {
        #expect(SeerrLiveRefreshCadence.request(try request(status: 1, mediaStatus: 2)) == .waitingForApproval)
        #expect(SeerrLiveRefreshCadence.request(try request(status: 2, mediaStatus: 3)) == .transferring)
        #expect(SeerrLiveRefreshCadence.request(try request(status: 2, mediaStatus: 4)) == .transferring)

        for settled in [
            try request(status: 3, mediaStatus: 1),
            try request(status: 4, mediaStatus: 3),
            try request(status: 5, mediaStatus: 5),
        ] {
            #expect(SeerrLiveRefreshCadence.request(settled) == nil)
        }
    }

    @Test func mediaDetailsFollowTheFastestUnsettledSignal() throws {
        #expect(SeerrLiveRefreshCadence.mediaDetails(try details(mediaStatus: 2)) == .waitingForApproval)
        #expect(SeerrLiveRefreshCadence.mediaDetails(try details(mediaStatus: 3)) == .transferring)
        #expect(
            SeerrLiveRefreshCadence.mediaDetails(
                try details(mediaStatus: 4, requestStatus: 2)
            ) == .transferring
        )
        #expect(
            SeerrLiveRefreshCadence.mediaDetails(
                try details(mediaStatus: 1, requestStatus: 1)
            ) == .waitingForApproval
        )
    }

    /// Jellyseerr can briefly leave old queue rows attached after import.
    /// Availability is authoritative, so that stale row must not poll forever.
    @Test func terminalMediaStopsEvenWithAStaleQueueRow() throws {
        let loaded = try JSONDecoder().decode(
            SeerrMediaDetails.self,
            from: Data(
                #"{"id":603,"mediaInfo":{"status":5,"downloadStatus":[{"downloadId":"old","size":100,"sizeLeft":0}]}}"#.utf8
            )
        )
        #expect(SeerrLiveRefreshCadence.mediaDetails(loaded) == nil)
    }

    private func request(status: Int, mediaStatus: Int) throws -> SeerrMediaRequest {
        try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(
                #"{"id":7,"status":\#(status),"type":"movie","media":{"id":1,"tmdbId":603,"status":\#(mediaStatus)}}"#.utf8
            )
        )
    }

    private func details(mediaStatus: Int, requestStatus: Int? = nil) throws -> SeerrMediaDetails {
        let requests = requestStatus.map {
            #", "requests":[{"id":7,"status":\#($0)}]"#
        } ?? ""
        return try JSONDecoder().decode(
            SeerrMediaDetails.self,
            from: Data(
                #"{"id":603,"mediaInfo":{"status":\#(mediaStatus)\#(requests)}}"#.utf8
            )
        )
    }
}

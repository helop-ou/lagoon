import Foundation
import Testing
@testable import Lagoon

/// The numbers here are Jellyseerr's `MediaRequestStatus` and `MediaStatus`
/// from `server/constants/media.ts`. They are the wire contract, so they are
/// asserted literally: getting one wrong is invisible until someone reads a
/// badge that is quietly lying (HEL-115).
@Suite("Seerr request and media status")
struct SeerrRequestStatusTests {
    @Test @MainActor func requestStatusNumbersMatchJellyseerr() {
        #expect(SeerrRequestStatus(apiValue: 1) == .pending)
        #expect(SeerrRequestStatus(apiValue: 2) == .approved)
        #expect(SeerrRequestStatus(apiValue: 3) == .declined)
        #expect(SeerrRequestStatus(apiValue: 4) == .failed)
        #expect(SeerrRequestStatus(apiValue: 5) == .completed)
    }

    /// The original bug: 4 and 5 were unknown to the enum and fell back to
    /// `.pending`, so a completed request said "Pending Approval" forever.
    @Test @MainActor func anUnrecognisedRequestStatusIsNeverReportedAsPending() {
        #expect(SeerrRequestStatus(apiValue: 99) == .unknown)
        #expect(SeerrRequestStatus(apiValue: 0) == .unknown)
        #expect(SeerrRequestStatus(apiValue: -3) == .unknown)
    }

    @Test @MainActor func mediaStatusNumbersMatchJellyseerr() {
        #expect(SeerrAvailabilityStatus(apiValue: 1) == .unknown)
        #expect(SeerrAvailabilityStatus(apiValue: 2) == .pending)
        #expect(SeerrAvailabilityStatus(apiValue: 3) == .processing)
        #expect(SeerrAvailabilityStatus(apiValue: 4) == .partiallyAvailable)
        #expect(SeerrAvailabilityStatus(apiValue: 5) == .available)
        // 6 used to be read as "deleted". It is blocklisted; deleted is 7.
        #expect(SeerrAvailabilityStatus(apiValue: 6) == .blocklisted)
        #expect(SeerrAvailabilityStatus(apiValue: 7) == .deleted)
    }

    /// Offering a Request button for a blocklisted title only earns a
    /// rejection from the server; a deleted one really can be asked for again.
    @Test @MainActor func onlyUnknownAndDeletedMediaCanBeRequested() {
        #expect(SeerrAvailabilityStatus.unknown.allowsRequesting)
        #expect(SeerrAvailabilityStatus.deleted.allowsRequesting)
        #expect(!SeerrAvailabilityStatus.blocklisted.allowsRequesting)
        #expect(!SeerrAvailabilityStatus.available.allowsRequesting)
        #expect(!SeerrAvailabilityStatus.pending.allowsRequesting)
        #expect(!SeerrAvailabilityStatus.processing.allowsRequesting)
        #expect(!SeerrAvailabilityStatus.partiallyAvailable.allowsRequesting)
    }

    // MARK: - Combined progress

    /// The reported symptom: approved-and-in-the-library must read
    /// "Available", not "Pending" and not "Approved".
    @Test @MainActor func anApprovedRequestThatHasArrivedReadsAsAvailable() {
        #expect(SeerrRequestProgress.resolve(request: .approved, availability: .available) == .available)
        #expect(SeerrRequestProgress.resolve(request: .completed, availability: .available) == .available)
    }

    @Test @MainActor func anApprovedRequestStillArrivingReadsAsProcessing() {
        for availability: SeerrAvailabilityStatus in [.unknown, .pending, .processing] {
            #expect(SeerrRequestProgress.resolve(request: .approved, availability: availability) == .processing)
        }
    }

    @Test @MainActor func aPartiallyAvailableShowSaysSo() {
        #expect(
            SeerrRequestProgress.resolve(request: .approved, availability: .partiallyAvailable)
                == .partiallyAvailable
        )
    }

    /// Availability must not overrule the approval state before approval:
    /// a pending request for a title that happens to be in the library is
    /// still pending.
    @Test @MainActor func approvalStateWinsUntilTheRequestIsGranted() {
        #expect(SeerrRequestProgress.resolve(request: .pending, availability: .available) == .pending)
        #expect(SeerrRequestProgress.resolve(request: .declined, availability: .available) == .declined)
        #expect(SeerrRequestProgress.resolve(request: .failed, availability: .available) == .failed)
    }

    @Test @MainActor func aFailedRequestIsNeverShownAsPending() {
        let progress = SeerrRequestProgress.resolve(request: .failed, availability: .processing)
        #expect(progress == .failed)
        #expect(progress.title == "Failed")
    }

    // MARK: - Decoding the real shape

    private func request(status: Int, mediaStatus: Int, mediaStatus4k: Int, is4k: Bool) throws -> SeerrMediaRequest {
        let json = """
        {"id":7,"status":\(status),"is4k":\(is4k),"type":"movie",
         "media":{"id":1,"tmdbId":603,"mediaType":"movie",
                  "status":\(mediaStatus),"status4k":\(mediaStatus4k)}}
        """
        return try JSONDecoder().decode(SeerrMediaRequest.self, from: Data(json.utf8))
    }

    @Test @MainActor func aCompletedRequestDecodesAndReadsAsAvailable() throws {
        let decoded = try request(status: 5, mediaStatus: 5, mediaStatus4k: 1, is4k: false)
        #expect(decoded.requestStatus == .completed)
        #expect(decoded.progress == .available)
        #expect(decoded.progress.title == "Available")
    }

    /// A 4K request is satisfied by the 4K copy. Reading `status` instead of
    /// `status4k` would call it available because the 1080p copy is there.
    @Test @MainActor func aFourKRequestReadsTheFourKAvailability() throws {
        let decoded = try request(status: 5, mediaStatus: 5, mediaStatus4k: 3, is4k: true)
        #expect(decoded.progress == .processing)

        let arrived = try request(status: 2, mediaStatus: 1, mediaStatus4k: 5, is4k: true)
        #expect(arrived.progress == .available)
    }

    @Test @MainActor func aNonFourKRequestIgnoresTheFourKAvailability() throws {
        let decoded = try request(status: 2, mediaStatus: 3, mediaStatus4k: 5, is4k: false)
        #expect(decoded.progress == .processing)
    }

    /// A request whose media object is missing entirely must not claim the
    /// title has arrived.
    @Test @MainActor func aRequestWithoutMediaIsNotReportedAsAvailable() throws {
        let decoded = try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(#"{"id":7,"status":2,"type":"movie"}"#.utf8)
        )
        #expect(decoded.progress == .processing)
    }

    @Test @MainActor func everyProgressCaseHasATitleAndASymbol() {
        let all: [SeerrRequestProgress] = [
            .pending, .declined, .failed, .processing, .partiallyAvailable, .available, .unknown,
        ]
        for progress in all {
            #expect(!progress.title.isEmpty)
            #expect(!progress.symbol.isEmpty)
        }
    }
}

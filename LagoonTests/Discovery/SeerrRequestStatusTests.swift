import Foundation
import Testing
@testable import Lagoon

/// The numbers are Jellyseerr's `MediaRequestStatus` and `MediaStatus` from
/// `server/constants/media.ts`, asserted literally as the wire contract.
@Suite("Seerr request and media status")
struct SeerrRequestStatusTests {
    @Test @MainActor func requestStatusNumbersMatchJellyseerr() {
        #expect(SeerrRequestStatus(apiValue: 1) == .pending)
        #expect(SeerrRequestStatus(apiValue: 2) == .approved)
        #expect(SeerrRequestStatus(apiValue: 3) == .declined)
        #expect(SeerrRequestStatus(apiValue: 4) == .failed)
        #expect(SeerrRequestStatus(apiValue: 5) == .completed)
    }

    /// An unknown status falling back to `.pending` shows "Pending Approval" forever.
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
        // 6 is blocklisted; deleted is 7.
        #expect(SeerrAvailabilityStatus(apiValue: 6) == .blocklisted)
        #expect(SeerrAvailabilityStatus(apiValue: 7) == .deleted)
    }

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

    /// Reading `status` instead of `status4k` would count the 1080p copy.
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

    @Test @MainActor func aRequestWithoutMediaIsNotReportedAsAvailable() throws {
        let decoded = try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(#"{"id":7,"status":2,"type":"movie"}"#.utf8)
        )
        #expect(decoded.progress == .processing)
    }

    @Test @MainActor func aGrantedRequestWhoseMediaWentAwaySaysSo() {
        #expect(SeerrRequestProgress.resolve(request: .completed, availability: .deleted) == .removed)
        #expect(SeerrRequestProgress.resolve(request: .approved, availability: .deleted) == .removed)
        #expect(SeerrRequestProgress.resolve(request: .completed, availability: .blocklisted) == .blocked)
    }

    /// Matches Jellyseerr's own check: MANAGE_BLOCKLIST, or admin.
    @Test @MainActor func onlyBlocklistManagersAndAdminsCanUnblock() {
        func user(permissions: Int) -> SeerrUser {
            try! JSONDecoder().decode(
                SeerrUser.self,
                from: Data(#"{"id":1,"permissions":\#(permissions)}"#.utf8)
            )
        }
        #expect(SeerrPermission.manageBlocklist.rawValue == 268_435_456)
        #expect(user(permissions: 268_435_456).canManageBlocklist)
        #expect(user(permissions: 2).canManageBlocklist, "admin overrides every permission")
        #expect(!user(permissions: 32).canManageBlocklist)
        #expect(!user(permissions: 0).canManageBlocklist)
    }

    @Test @MainActor func onlyUnsettledStatesAnimate() {
        #expect(SeerrRequestProgress.processing.motion == .rotate)
        #expect(SeerrRequestProgress.pending.motion == .pulse)
        for settled: SeerrRequestProgress in [
            .available, .partiallyAvailable, .declined, .failed, .removed, .blocked, .unknown,
        ] {
            #expect(settled.motion == .still, "\(settled) should not animate")
        }
    }

    @Test @MainActor func everyProgressCaseHasATitleAndASymbol() {
        let all: [SeerrRequestProgress] = [
            .pending, .declined, .failed, .processing, .partiallyAvailable,
            .available, .removed, .blocked, .unknown,
        ]
        for progress in all {
            #expect(!progress.title.isEmpty)
            #expect(!progress.symbol.isEmpty)
        }
    }
}

@Suite("Seerr quality profiles")
struct SeerrQualityProfileTests {
    /// Profile names come from `service/{radarr,sonarr}/{id}`; older servers
    /// may omit either side.
    @Test @MainActor func aRequestCarriesTheProfileAndServerItWasMadeAgainst() throws {
        let request = try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(#"{"id":1,"status":1,"type":"movie","profileId":4,"serverId":0}"#.utf8)
        )
        #expect(request.profileId == 4)
        #expect(request.serverId == 0)
    }

    @Test @MainActor func aRequestWithoutAProfileStillDecodes() throws {
        let request = try JSONDecoder().decode(
            SeerrMediaRequest.self,
            from: Data(#"{"id":1,"status":1,"type":"movie"}"#.utf8)
        )
        #expect(request.profileId == nil)
        #expect(request.serverId == nil)
    }

    /// The exact shape `service/radarr/0` returns on the test server.
    @Test @MainActor func theServiceProfilesDecode() throws {
        let json = """
        {"server":{"id":0},"rootFolders":[{"id":1,"path":"/movies"}],"tags":[],
         "profiles":[{"id":1,"name":"Any"},{"id":4,"name":"HD-1080p"},{"id":7,"name":"HD/UHD"}]}
        """
        let details = try JSONDecoder().decode(SeerrServiceDetails.self, from: Data(json.utf8))
        #expect(details.profiles.count == 3)
        #expect(details.profiles.first { $0.id == 7 }?.name == "HD/UHD")
    }

    /// Used to find the default server when a request names none.
    @Test @MainActor func theServiceListDecodesAndMarksTheDefault() throws {
        let json = """
        [{"id":0,"name":"Radarr","is4k":false,"isDefault":true,"activeProfileId":7,"activeTags":[]}]
        """
        let services = try JSONDecoder().decode([SeerrService].self, from: Data(json.utf8))
        #expect(services.count == 1)
        #expect(services[0].isDefault)
        #expect(!services[0].is4k)
        #expect(services[0].name == "Radarr")
    }

    @Test @MainActor func aServiceMissingItsFieldsDoesNotThrow() throws {
        let services = try JSONDecoder().decode([SeerrService].self, from: Data("[{}]".utf8))
        #expect(services[0].id == 0)
        #expect(!services[0].isDefault)
    }
}

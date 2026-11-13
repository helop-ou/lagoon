import Foundation
@testable import Lagoon
import Testing

/// On Apple TV the Request button was swapped for a status button once the
/// request went through, and the focus fell to the tab bar. One button now
/// draws every state, so these are the states it has to cover.
struct SeerrPrimaryActionTests {
    private typealias Context = SeerrPrimaryAction.Context

    @Test func aMovieNobodyAskedForIsRequestedAfterConfirming() throws {
        for availability in [SeerrAvailabilityStatus.unknown, .deleted] {
            let action = try #require(SeerrPrimaryAction.resolve(Context(availability: availability, canRequest: true)))
            #expect(action.tap == .confirmMovieRequest)
            #expect(action.identifier == "seerr.detail.request")
            #expect(action.symbol == "plus")
        }
    }

    @Test func aShowNobodyAskedForOpensTheSeasonChoice() throws {
        let action = try #require(SeerrPrimaryAction.resolve(Context(mediaType: .tv, canRequest: true)))
        #expect(action.tap == .chooseSeasons)
        #expect(action.identifier == "seerr.detail.request")
    }

    @Test func aViewerWithoutPermissionIsToldWhy() throws {
        let action = try #require(SeerrPrimaryAction.resolve(Context(canRequest: false)))
        guard case .explain = action.tap else {
            Issue.record("\(action.tap) is not an explanation")
            return
        }
        #expect(action.symbol == "lock")
        #expect(action.identifier == "seerr.detail.status")
    }

    /// The states a request moves the button through, which is where the
    /// focus was lost.
    @Test func aSentRequestBecomesAStatusOnTheSameButton() throws {
        let pending = try #require(SeerrPrimaryAction.resolve(Context(availability: .pending, canRequest: true)))
        #expect(pending.title == SeerrAvailabilityStatus.pending.title)
        #expect(pending.symbol == "clock")
        #expect(pending.motion == .pulse)
        #expect(pending.tap == .explain("This request is waiting for approval."))

        let processing = try #require(SeerrPrimaryAction.resolve(Context(availability: .processing, canRequest: true)))
        #expect(processing.title == SeerrAvailabilityStatus.processing.title)
        #expect(processing.motion == .rotate)
        #expect(processing.tap == .explain("This title has been approved and is being added to your library."))
    }

    @Test func aDownloadShowsItsProgressOnlyWhileProcessing() throws {
        let progress = try #require(SeerrDownloadProgress(items: [try Self.download(size: 1_000, left: 250)]))
        let processing = try #require(SeerrPrimaryAction.resolve(
            Context(availability: .processing, downloadProgress: progress)
        ))
        #expect(processing.title == "75%")
        #expect(processing.motion == .bounce)
        #expect(processing.tap == .explain(progress.summary))

        let pending = try #require(SeerrPrimaryAction.resolve(
            Context(availability: .pending, downloadProgress: progress)
        ))
        #expect(pending.title == SeerrAvailabilityStatus.pending.title)
    }

    @Test func aFinishedDownloadSaysItIsImporting() throws {
        let progress = try #require(SeerrDownloadProgress(items: [try Self.download(size: 1_000, left: 0)]))
        let action = try #require(SeerrPrimaryAction.resolve(
            Context(availability: .processing, downloadProgress: progress)
        ))
        #expect(action.symbol == "square.and.arrow.down")
        #expect(action.title != progress.percentText)
    }

    @Test func aTitleInTheLibraryOpensInLagoonInstead() {
        #expect(SeerrPrimaryAction.resolve(Context(availability: .available, isInLibrary: true)) == nil)
        #expect(SeerrPrimaryAction.resolve(
            Context(availability: .partiallyAvailable, isInLibrary: true, canRequestMoreSeasons: true)
        ) == nil)
        // Only those two: a pending title Jellyfin happens to hold is still a request.
        #expect(SeerrPrimaryAction.resolve(Context(availability: .pending, isInLibrary: true)) != nil)
    }

    @Test func anAvailableTitleLagoonCannotMatchSaysSo() throws {
        let action = try #require(SeerrPrimaryAction.resolve(Context(availability: .available)))
        #expect(action.title == "Available in Jellyfin")
        guard case .explain = action.tap else {
            Issue.record("\(action.tap) is not an explanation")
            return
        }
    }

    @Test func aPartlyAvailableShowOffersTheSeasonsStillMissing() {
        #expect(SeerrPrimaryAction.resolve(
            Context(availability: .partiallyAvailable, mediaType: .tv, canRequestMoreSeasons: true)
        ) == .requestMoreSeasons)
        #expect(SeerrPrimaryAction.requestMoreSeasons.tap == .chooseSeasons)
        #expect(SeerrPrimaryAction.resolve(
            Context(availability: .partiallyAvailable, mediaType: .tv)
        ) == .partiallyAvailable)
    }

    @Test func aBlockedTitleIsUnblockedOnlyByWhoMayManageTheBlocklist() throws {
        let manager = try #require(SeerrPrimaryAction.resolve(
            Context(availability: .blocklisted, canRequest: true, canManageBlocklist: true)
        ))
        #expect(manager.tap == .confirmUnblock)
        #expect(manager.identifier == "seerr.detail.unblock")

        let viewer = try #require(SeerrPrimaryAction.resolve(Context(availability: .blocklisted, canRequest: true)))
        #expect(viewer.title == SeerrAvailabilityStatus.blocklisted.title)
        guard case .explain = viewer.tap else {
            Issue.record("\(viewer.tap) is not an explanation")
            return
        }
    }

    private static func download(size: Int64, left: Int64) throws -> SeerrDownloadItem {
        let json = """
        {"downloadId": "a", "size": \(size), "sizeLeft": \(left), "status": "downloading", "timeLeft": "00:10:00"}
        """
        return try JSONDecoder().decode(SeerrDownloadItem.self, from: Data(json.utf8))
    }
}

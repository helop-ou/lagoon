import Foundation
import Testing
@testable import Lagoon

/// Pure coverage for the background session delegate's supporting logic
/// (HEL-166 review): the task-description wire format, the finished-vs-failed
/// classification a download's HTTP status and byte count decide, and the
/// short copy a transport error is mapped to. None of these touch a session,
/// a manifest or a clock, so a delegate callback and the store's own
/// reporting path can both be pinned down without either.
@Suite("Download task description")
struct DownloadTaskDescriptionTests {
    @Test func parsesAllFourFields() {
        let raw = "item1|item1.mp4|accountkey|attempt-1"
        let info = DownloadTaskDescription.parse(raw)
        #expect(info?.itemID == "item1")
        #expect(info?.fileName == "item1.mp4")
        #expect(info?.accountKey == "accountkey")
        #expect(info?.attemptToken == "attempt-1")
    }

    @Test func rawRoundTripsThroughParse() {
        let info = DownloadTaskDescription(itemID: "item2", fileName: "item2.ts", accountKey: "key2", attemptToken: "attempt-2")
        #expect(DownloadTaskDescription.parse(info.raw) == info)
    }

    @Test func returnsNilForANilDescription() {
        #expect(DownloadTaskDescription.parse(nil) == nil)
    }

    @Test func returnsNilWhenAFieldIsMissing() {
        // The pre-HEL-166-review wire format carried only three fields; a
        // task that survived a relaunch from before this change must not be
        // misparsed into a bogus attempt token.
        #expect(DownloadTaskDescription.parse("item1|item1.mp4|accountkey") == nil)
    }

    @Test func returnsNilForGarbage() {
        #expect(DownloadTaskDescription.parse("not-a-task-description") == nil)
    }
}

@Suite("Download completion outcome")
struct DownloadCompletionTests {
    @Test func non2xxStatusFails() {
        let outcome = DownloadCompletion.outcome(status: 500, bytesOnDisk: 100, expectedBytes: 100, quality: .original)
        #expect(outcome == .failed(reason: "HTTP 500"))
    }

    @Test func status403HasItsOwnReason() {
        let outcome = DownloadCompletion.outcome(status: 403, bytesOnDisk: 0, expectedBytes: nil, quality: .original)
        #expect(outcome == .failed(reason: "Not permitted by the server"))
    }

    @Test func originalSizeMismatchIsIncomplete() {
        let outcome = DownloadCompletion.outcome(status: 200, bytesOnDisk: 90, expectedBytes: 100, quality: .original)
        #expect(outcome == .failed(reason: "Incomplete file"))
    }

    @Test func originalWithMatchingSizeCompletes() {
        let outcome = DownloadCompletion.outcome(status: 200, bytesOnDisk: 100, expectedBytes: 100, quality: .original)
        #expect(outcome == .complete(bytes: 100))
    }

    @Test func originalWithNoExpectedSizeCompletesRegardless() {
        let outcome = DownloadCompletion.outcome(status: 200, bytesOnDisk: 100, expectedBytes: nil, quality: .original)
        #expect(outcome == .complete(bytes: 100))
    }

    @Test func emptySuccessfulResponseIsNeverAPlayableDownload() {
        for quality in DownloadQuality.allCases {
            #expect(DownloadCompletion.outcome(status: 200, bytesOnDisk: 0, expectedBytes: nil, quality: quality)
                == .failed(reason: "Incomplete file"))
        }
    }

    @Test func transcodeCompletesAtAnySizeOnceStatusIsGood() {
        // A progressive transcode's expected size is only ever an estimate;
        // it must never fail a finished download over a mismatch.
        let outcome = DownloadCompletion.outcome(status: 200, bytesOnDisk: 1, expectedBytes: 999_999, quality: .high)
        #expect(outcome == .complete(bytes: 1))
    }
}

@Suite("Download transport failure copy")
struct DownloadTransportFailureTests {
    @Test func cancelledMapsToNoText() {
        #expect(DownloadTransportFailure.failureDescription(domain: NSURLErrorDomain, code: NSURLErrorCancelled) == nil)
    }

    @Test func networkLostAndSimilarMapToConnectionLost() {
        for code in [NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet, NSURLErrorTimedOut] {
            #expect(DownloadTransportFailure.failureDescription(domain: NSURLErrorDomain, code: code) == "Connection lost")
        }
    }

    @Test func unreachableHostMapsToServerUnreachable() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost] {
            #expect(DownloadTransportFailure.failureDescription(domain: NSURLErrorDomain, code: code) == "Server unreachable")
        }
    }

    @Test func diskFullMapsToNotEnoughSpace() {
        #expect(DownloadTransportFailure.failureDescription(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) == "Not enough space")
    }

    @Test func anythingElseMapsToAGenericFailure() {
        #expect(DownloadTransportFailure.failureDescription(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse) == "Download failed")
    }
}

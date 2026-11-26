import Foundation
import Testing
@testable import Lagoon

@Suite("Unplayable reasons")
struct UnplayableReasonTests {
    @Test func anAnswerWithASourcePlaysIt() throws {
        #expect(try info(#"{"MediaSources":[{"Id":"m1"}]}"#).playableSource().id == "m1")
    }

    /// Jellyfin sends `NoCompatibleStream` with the empty list, for an
    /// episode it has no file for.
    @Test func noSourceIsTheReasonWhenTheListIsEmpty() throws {
        #expect(reason(#"{"MediaSources":[],"ErrorCode":"NoCompatibleStream"}"#) == .noSource)
        #expect(reason(#"{}"#) == .noSource)
    }

    @Test(arguments: [
        ("NotAllowed", UnplayableReason.notAllowed),
        ("RateLimitExceeded", .rateLimited),
        ("NoCompatibleStream", .refused),
        ("Something New", .refused),
    ])
    func aRefusalWithASourceIsNamedByTheServersCode(code: String, expected: UnplayableReason) {
        #expect(reason(#"{"MediaSources":[{"Id":"m1"}],"ErrorCode":"\#(code)"}"#) == expected)
    }

    @Test func aMissingFileSaysSoAndNotThatTheDeviceCannotPlayIt() {
        #expect(JellyfinError.unplayable(.noSource).errorDescription == "The server has no file for this item.")
        #expect(JellyfinError.unplayable(.noRoute).errorDescription == "This item can't be played on this device.")
    }

    private func info(_ json: String) throws -> PlaybackInfoResponse {
        try JellyfinClient.decoder.decode(PlaybackInfoResponse.self, from: Data(json.utf8))
    }

    private func reason(_ json: String) -> UnplayableReason? {
        do {
            _ = try info(json).playableSource()
        } catch JellyfinError.unplayable(let reason) {
            return reason
        } catch {}
        return nil
    }
}

import Foundation
import Testing
@testable import Lagoon

/// What the Subtitles tab says once every language search has answered.
@Suite("Subtitle search phase")
struct SubtitleSearchPhaseTests {
    private func match(_ id: String) throws -> RemoteSubtitleInfo {
        try JellyfinClient.decoder.decode(
            RemoteSubtitleInfo.self,
            from: Data(#"{"Id":"\#(id)","ThreeLetterISOLanguageName":"eng"}"#.utf8)
        )
    }

    private typealias Outcome = Result<[RemoteSubtitleInfo], Error>

    private func phase(_ outcomes: [Outcome]) throws -> SubtitleSearchPhase {
        try #require(SubtitleSearchCoordinator.resolveSearch(outcomes)).phase
    }

    private let missing: Outcome = .failure(JellyfinError.server(status: 404))

    @Test func everyLanguageAnsweringNotFoundMeansNoProvider() throws {
        #expect(try phase([missing, missing]) == .noProvider)
    }

    @Test func aLanguageThatSearchedCleanlyMakesNotFoundNoResults() throws {
        #expect(try phase([missing, .success([])]) == .noResults)
    }

    @Test func emptyAnswersMeanNoResults() throws {
        #expect(try phase([.success([]), .success([])]) == .noResults)
        #expect(try phase([]) == .noResults)
    }

    @Test func aFailureIsReportedWithItsOwnWording() throws {
        let failure = SubtitleDownloadError.rateLimited
        #expect(try phase([.failure(JellyfinError.server(status: 429))])
            == .failed(failure.localizedDescription))
    }

    @Test func aMissingPermissionOutranksEveryOtherFailure() throws {
        let outcomes: [Outcome] = [
            .failure(JellyfinError.server(status: 429)),
            .failure(JellyfinError.server(status: 403)),
            .failure(JellyfinError.server(status: 401)),
        ]
        #expect(try phase(outcomes) == .notPermitted)
    }

    @Test func anExpiredSessionOutranksOtherFailures() throws {
        let outcomes: [Outcome] = [
            .failure(JellyfinError.server(status: 429)),
            .failure(JellyfinError.server(status: 401)),
        ]
        #expect(try phase(outcomes) == .failed(SubtitleDownloadError.sessionExpired.localizedDescription))
    }

    @Test func resultsFromOneLanguageSurviveAnotherLanguageFailing() throws {
        let resolved = try #require(SubtitleSearchCoordinator.resolveSearch([
            .failure(JellyfinError.server(status: 429)),
            .success([try match("a"), try match("b")]),
        ]))
        #expect(resolved.phase == .idle)
        #expect(resolved.results.map(\.providerID) == ["a", "b"])
    }

    @Test func resultsAreDeduplicatedInRequestOrder() throws {
        let resolved = try #require(SubtitleSearchCoordinator.resolveSearch([
            .success([try match("a"), try match("b")]),
            .success([try match("b"), try match("c")]),
        ]))
        #expect(resolved.results.map(\.providerID) == ["a", "b", "c"])
    }

    @Test func aCancelledLanguageAbandonsTheSearch() throws {
        #expect(SubtitleSearchCoordinator.resolveSearch([
            .success([try match("a")]),
            .failure(CancellationError()),
        ]) == nil)
    }
}

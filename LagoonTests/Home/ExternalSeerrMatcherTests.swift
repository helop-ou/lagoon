import Foundation
import Testing
@testable import Lagoon

@Suite("External Seerr matcher")
struct ExternalSeerrMatcherTests {
    private func item(_ json: String) throws -> JellyfinClient.ExternalSectionItem {
        try JellyfinClient.decoder.decode(JellyfinClient.ExternalSectionItem.self, from: Data(json.utf8))
    }

    private func results(_ json: String) throws -> [SeerrDiscoverResult] {
        try JSONDecoder().decode([SeerrDiscoverResult].self, from: Data(json.utf8))
    }

    /// Sonarr's titles come from TVDB and Seerr's from TMDB.
    @Test func titlesMatchWhateverTheirAccentsCaseAndPunctuation() throws {
        let show = try item(#"{"Name":"90 Day Fiancé: The Other Way","ProviderIds":{"SonarrEpisodeId":"1"}}"#)
        let found = try results(#"[{"id":1,"mediaType":"movie","title":"90 Day Fiance - The Other Way"},{"id":90046,"mediaType":"tv","name":"90 Day Fiance - The Other Way"}]"#)

        #expect(ExternalSeerrMatcher.match(show, in: found)?.id == 90046)
    }

    @Test func aMovieOfAnotherYearOrATitleThatOnlyStartsTheSameIsNoMatch() throws {
        let movie = try item(#"{"Name":"The Odyssey","ProductionYear":2026,"ProviderIds":{"RadarrMovieId":"1"}}"#)
        let found = try results(#"[{"id":1,"mediaType":"movie","title":"The Odyssey","releaseDate":"1997-05-18"},{"id":2,"mediaType":"movie","title":"The Odyssey Returns","releaseDate":"2026-07-17"}]"#)

        #expect(ExternalSeerrMatcher.match(movie, in: found) == nil)
    }

    @Test func aCardOpensSignInWhileSignedOutAndThePageOnceFound() throws {
        let show = try item(#"{"Name":"Abbott Elementary","ProviderIds":{"SonarrEpisodeId":"1"}}"#)
        let album = try item(#"{"Name":"Album","ProviderIds":{"LidarrAlbumId":"7"}}"#)
        let found = ExternalSeerrTitle(id: 125935, mediaType: .tv, backdropPath: nil)

        #expect(ExternalSeerrMatcher.route(for: show, seerrTitle: nil, isSignedIn: false) == .signIn(then: show))
        #expect(ExternalSeerrMatcher.route(for: show, seerrTitle: found, isSignedIn: true) == .media(id: 125935, type: .tv))
        #expect(ExternalSeerrMatcher.route(for: show, seerrTitle: nil, isSignedIn: true) == nil)
        #expect(ExternalSeerrMatcher.route(for: album, seerrTitle: nil, isSignedIn: false) == nil)
    }

    @Test func onlySonarrAndRadarrTitlesAreSearched() throws {
        let found = try results(#"[{"id":7,"mediaType":"movie","title":"Album"}]"#)
        let seerr = try item(#"{"Name":"Album","SourceType":"movie","ProviderIds":{"Jellyseerr":"7"}}"#)
        let album = try item(#"{"Name":"Album","ProviderIds":{"LidarrAlbumId":"7"}}"#)

        #expect(ExternalSeerrMatcher.match(seerr, in: found) == nil)
        #expect(ExternalSeerrMatcher.match(album, in: found) == nil)
    }
}

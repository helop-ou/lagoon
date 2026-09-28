import Foundation
import Testing
@testable import Lagoon

@Suite("Seerr media details")
struct SeerrMediaDetailsTests {
    private func decode(_ json: String) throws -> SeerrMediaDetails {
        try JSONDecoder().decode(SeerrMediaDetails.self, from: Data(json.utf8))
    }

    @Test func movieCertificationPrefersTheViewersRegionThenTheUS() throws {
        let details = try decode("""
        {"id": 27205, "title": "Inception",
         "releases": {"results": [
           {"iso_3166_1": "AE", "release_dates": [{"certification": "", "type": 3}]},
           {"iso_3166_1": "GB", "release_dates": [{"certification": "12A", "type": 3}]},
           {"iso_3166_1": "US", "release_dates": [{"certification": "", "type": 2}, {"certification": "PG-13", "type": 3}]}
         ]}}
        """)
        #expect(details.officialRating(region: "GB") == "12A")
        #expect(details.officialRating(region: "gb") == "12A")
        #expect(details.officialRating(region: "EE") == "PG-13")
        #expect(details.officialRating(region: nil) == "PG-13")
    }

    @Test func showCertificationUsesContentRatings() throws {
        let details = try decode("""
        {"id": 1396, "name": "Breaking Bad",
         "contentRatings": {"results": [
           {"descriptors": [], "iso_3166_1": "DE", "rating": "16"},
           {"descriptors": [], "iso_3166_1": "US", "rating": "TV-MA"}
         ]}}
        """)
        #expect(details.officialRating(region: "DE") == "16")
        #expect(details.officialRating(region: "FR") == "TV-MA")
    }

    @Test func noCertificationAnywhereIsNil() throws {
        let bare = try decode("""
        {"id": 1, "title": "Untitled"}
        """)
        #expect(bare.officialRating(region: "US") == nil)

        let foreignOnly = try decode("""
        {"id": 2, "title": "Elsewhere",
         "releases": {"results": [{"iso_3166_1": "JP", "release_dates": [{"certification": "G"}]}]}}
        """)
        #expect(foreignOnly.officialRating(region: "EE") == nil)
    }

    @Test func creditsDecodeWithTheirProfilePaths() throws {
        let details = try decode("""
        {"id": 27205, "title": "Inception",
         "credits": {
           "cast": [{"castId": 1, "character": "Cobb", "creditId": "c1", "id": 6193, "name": "Leonardo DiCaprio", "order": 0, "profilePath": "/leo.jpg"}],
           "crew": [{"creditId": "c2", "department": "Directing", "id": 525, "job": "Director", "name": "Christopher Nolan", "profilePath": null}]
         }}
        """)
        let credits = try #require(details.credits)
        #expect(credits.cast.first?.character == "Cobb")
        #expect(credits.cast.first?.profilePath == "/leo.jpg")
        #expect(credits.crew.first?.job == "Director")
        #expect(credits.crew.first?.profilePath == nil)
    }

    @Test func aCreditWithoutIdsDoesNotFailThePage() throws {
        let details = try decode("""
        {"id": 27205, "title": "Inception",
         "credits": {"cast": [{"name": "Unknown", "id": 7}], "crew": [{"job": "Editor"}]}}
        """)
        #expect(details.credits?.cast.first?.creditId == "person-7")
        #expect(details.credits?.crew.first?.creditId == "crew-0")
    }

    @Test func detailsWithoutCreditsOrRatingsStillDecode() throws {
        let details = try decode("""
        {"id": 3, "name": "Minimal", "mediaInfo": {"status": 5}}
        """)
        #expect(details.credits == nil)
        #expect(details.releases == nil)
        #expect(details.contentRatings == nil)
        #expect(details.mediaInfo?.availability == .available)
    }

    private func show(mediaInfo: String) throws -> SeerrMediaDetails {
        try decode("""
        {"id": 60625, "name": "Show",
         "seasons": [
           {"id": 100, "seasonNumber": 0, "name": "Specials"},
           {"id": 101, "seasonNumber": 1}, {"id": 102, "seasonNumber": 2},
           {"id": 103, "seasonNumber": 3}, {"id": 104, "seasonNumber": 4}
         ],
         "mediaInfo": \(mediaInfo)}
        """)
    }

    private func requestable(_ details: SeerrMediaDetails, includingSpecials: Bool = false) -> [Int] {
        details.requestableSeasons(includingSpecials: includingSpecials).map(\.seasonNumber)
    }

    @Test func anAvailableShowStillOffersASeasonNobodyRequested() throws {
        let details = try show(mediaInfo: """
        {"status": 5, "seasons": [
          {"id": 1, "seasonNumber": 1, "status": 5}, {"id": 2, "seasonNumber": 2, "status": 5},
          {"id": 3, "seasonNumber": 3, "status": 5}, {"id": 4, "seasonNumber": 4, "status": 1}
        ]}
        """)
        #expect(requestable(details) == [4])
    }

    @Test func aProcessingShowOffersTheSeasonsOutsideItsRequest() throws {
        let details = try show(mediaInfo: """
        {"status": 3,
         "seasons": [{"id": 1, "seasonNumber": 1, "status": 3}],
         "requests": [{"id": 9, "status": 2, "seasons": [{"id": 1, "seasonNumber": 1, "status": 2}]}]}
        """)
        #expect(requestable(details) == [2, 3, 4])
    }

    @Test func aSeasonOnItsWayOrPartlyHereIsNotRequestableAgain() throws {
        // Another user's request shows only as the season's status.
        let details = try show(mediaInfo: """
        {"status": 4, "seasons": [
          {"id": 1, "seasonNumber": 1, "status": 2}, {"id": 2, "seasonNumber": 2, "status": 3},
          {"id": 3, "seasonNumber": 3, "status": 4}, {"id": 4, "seasonNumber": 4, "status": 7}
        ]}
        """)
        #expect(requestable(details) == [4])
    }

    @Test func declinedAnd4KRequestsLeaveTheirSeasonsRequestable() throws {
        let details = try show(mediaInfo: """
        {"status": 4,
         "seasons": [{"id": 1, "seasonNumber": 1, "status": 5}],
         "requests": [
           {"id": 7, "status": 3, "seasons": [{"id": 2, "seasonNumber": 2}]},
           {"id": 8, "status": 1, "is4k": true, "seasons": [{"id": 3, "seasonNumber": 3}]},
           {"id": 9, "status": 1, "is4k": false, "seasons": [{"id": 4, "seasonNumber": 4}]}
         ]}
        """)
        #expect(requestable(details) == [2, 3])
    }

    @Test func specialsAreRequestableOnlyWhenTheServerOffersThem() throws {
        let details = try show(mediaInfo: #"{"status": 1}"#)
        #expect(requestable(details) == [1, 2, 3, 4])
        #expect(requestable(details, includingSpecials: true) == [0, 1, 2, 3, 4])
    }

    @Test func aFullyRequestedShowHasNothingLeftToRequest() throws {
        let details = try show(mediaInfo: """
        {"status": 5, "seasons": [
          {"id": 1, "seasonNumber": 1, "status": 5}, {"id": 2, "seasonNumber": 2, "status": 5},
          {"id": 3, "seasonNumber": 3, "status": 5}, {"id": 4, "seasonNumber": 4, "status": 5}
        ]}
        """)
        #expect(requestable(details).isEmpty)
    }
}

import Foundation
import Testing
@testable import Lagoon

@Suite("TMDB title logos")
struct TMDBLogoSelectionTests {
    @Test func requestedLanguagesPutTheViewerFirstThenEnglishThenWordless() {
        #expect(TMDBLogoSelection.requestedLanguages(preferred: "et") == ["et", "en", "null"])
        #expect(TMDBLogoSelection.requestedLanguages(preferred: "en") == ["en", "null"])
        #expect(TMDBLogoSelection.requestedLanguages(preferred: nil) == ["en", "null"])
        #expect(TMDBLogoSelection.requestedLanguages(preferred: "") == ["en", "null"])
    }

    @Test func picksTheViewersLanguageBeforeEnglishBeforeWordless() {
        let logos = [
            TMDBLogo(filePath: "/plain.png", language: nil, voteAverage: 9),
            TMDBLogo(filePath: "/english.png", language: "en", voteAverage: 5),
            TMDBLogo(filePath: "/estonian.png", language: "et", voteAverage: 1),
        ]
        #expect(TMDBLogoSelection.pick(from: logos, languages: ["et", "en", "null"])?.filePath == "/estonian.png")
        #expect(TMDBLogoSelection.pick(from: logos, languages: ["en", "null"])?.filePath == "/english.png")
        #expect(TMDBLogoSelection.pick(from: logos, languages: ["de", "null"])?.filePath == "/plain.png")
    }

    @Test func withinALanguageTheBestVotedThenLargestWins() {
        let logos = [
            TMDBLogo(filePath: "/small.png", language: "en", voteAverage: 5, width: 400),
            TMDBLogo(filePath: "/large.png", language: "en", voteAverage: 5, width: 1600),
            TMDBLogo(filePath: "/liked.png", language: "en", voteAverage: 6, width: 300),
        ]
        #expect(TMDBLogoSelection.pick(from: logos, languages: ["en"])?.filePath == "/liked.png")
        #expect(TMDBLogoSelection.pick(from: Array(logos.prefix(2)), languages: ["en"])?.filePath == "/large.png")
    }

    @Test func skipsSVGLogosTheImageLoaderCannotDecode() {
        let logos = [
            TMDBLogo(filePath: "/vector.svg", language: "en", voteAverage: 10),
            TMDBLogo(filePath: "/raster.PNG", language: "en", voteAverage: 1),
        ]
        #expect(TMDBLogoSelection.pick(from: logos, languages: ["en"])?.filePath == "/raster.PNG")
        #expect(TMDBLogoSelection.pick(from: [logos[0]], languages: ["en", "null"]) == nil)
    }

    @Test func decodesTMDBsSnakeCaseImageList() throws {
        let json = """
        {"id": 27205, "backdrops": [], "posters": [],
         "logos": [
           {"aspect_ratio": 3.2, "height": 500, "iso_639_1": "en", "file_path": "/inception.png", "vote_average": 5.3, "vote_count": 4, "width": 1600},
           {"aspect_ratio": 3.2, "height": 500, "iso_639_1": null, "file_path": "/mark.svg", "vote_average": 0, "vote_count": 0, "width": 1600}
         ]}
        """
        let images = try JSONDecoder().decode(TMDBImages.self, from: Data(json.utf8))
        #expect(images.logos.count == 2)
        #expect(images.logos[0] == TMDBLogo(filePath: "/inception.png", language: "en", voteAverage: 5.3, width: 1600))
        #expect(images.logos[1].language == nil)
    }

    @Test func aMissingKeyDisablesTheProviderWithoutARequest() async {
        let provider = TMDBLogoProvider(apiKey: nil, preferredLanguage: "en")
        #expect(!provider.isEnabled)
        #expect(await provider.logoPath(id: 27205, mediaType: .movie) == nil)
    }

    @Test func blankKeysCountAsMissing() {
        UserDefaults.standard.removeObject(forKey: TMDBConfiguration.apiKeyOverrideKey)
        defer { UserDefaults.standard.removeObject(forKey: TMDBConfiguration.apiKeyOverrideKey) }
        UserDefaults.standard.set("   ", forKey: TMDBConfiguration.apiKeyOverrideKey)
        #expect(TMDBConfiguration.resolvedAPIKey == nil)
        UserDefaults.standard.set(" abc ", forKey: TMDBConfiguration.apiKeyOverrideKey)
        #expect(TMDBConfiguration.resolvedAPIKey == "abc")
    }
}

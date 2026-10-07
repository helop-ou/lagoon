import UIKit
import Testing
@testable import Lagoon

@Suite("Content icons")
struct ContentIconTests {
    @Test @MainActor func everyContentIconResolvesToARealSymbol() {
        // A missing SF Symbol renders as nothing, with no crash or warning.
        for name in [
            ContentIcon.home,
            ContentIcon.discover,
            ContentIcon.movies,
            ContentIcon.shows,
            ContentIcon.libraries,
            ContentIcon.search,
            ContentIcon.settings,
            ContentIcon.Settings.account,
            ContentIcon.Settings.playback,
            ContentIcon.Settings.audio,
            ContentIcon.Settings.subtitles,
            ContentIcon.Settings.advanced,
            ContentIcon.Settings.developer,
            ContentIcon.Settings.about,
            ContentIcon.library(collectionType: "tvshows"),
            ContentIcon.library(collectionType: "movies"),
            ContentIcon.library(collectionType: nil),
        ] {
            #expect(UIImage(systemName: name) != nil, "no SF Symbol named \(name)")
        }

        // Movies and Shows must not collapse to the same glyph, or the tabs
        // stop telling you which library you are in.
        #expect(ContentIcon.movies != ContentIcon.shows)
        #expect(ContentIcon.library(collectionType: "tvshows") == ContentIcon.shows)
        #expect(ContentIcon.library(collectionType: nil) == ContentIcon.movies)
    }
}

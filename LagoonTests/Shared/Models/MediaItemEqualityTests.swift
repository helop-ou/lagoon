import Foundation
import Testing
@testable import Lagoon

/// Why `MediaItem` compares by value: SwiftUI drops a `@State`
/// write whose new value compares equal to the old one, and the id-only `==`
/// the model used to have made a re-fetched item with a new resume point
/// "equal" to the stale one, so the detail page never re-rendered.
@Suite("MediaItem equality")
struct MediaItemEqualityTests {
    private func item(position: Int64) throws -> MediaItem {
        let json = """
        {"Id": "abc", "Name": "Bury the Devil", "Type": "Movie",
         "UserData": {"PlaybackPositionTicks": \(position), "Played": false}}
        """
        return try JellyfinClient.decoder.decode(MediaItem.self, from: Data(json.utf8))
    }

    @Test func aNewResumePointMakesADifferentItem() throws {
        #expect(try item(position: 100) != item(position: 200))
        #expect(try item(position: 100) == item(position: 100))
    }

    /// The navigation stack still treats every copy of an item as one
    /// destination, however stale its user data.
    @Test func theSameItemIsTheSameDestinationWhateverItsResumePoint() throws {
        let before = ContentNavigationRoute.item(try item(position: 100))
        let after = ContentNavigationRoute.item(try item(position: 200))
        #expect(before == after)
        #expect(before.hashValue == after.hashValue)
        #expect(Set([before, after]).count == 1)
    }
}

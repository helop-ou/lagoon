#if os(iOS)
import SwiftUI
import Testing
@testable import Lagoon

@Suite("Readable form column")
@MainActor
struct ReadableColumnTests {
    @Test func aWidePageCentresAColumnOfTheReadableWidth() {
        #expect(ReadableColumn.margin(in: 1376, isWide: true) == 338)
        #expect(ReadableColumn.margin(in: 1032, isWide: true) == 166)
    }

    /// An open iPhone Duo is wide but narrower than the column.
    @Test func aPageNoWiderThanTheColumnKeepsTheSystemMargin() {
        #expect(ReadableColumn.margin(in: 669, isWide: true) == nil)
        #expect(ReadableColumn.margin(in: Metrics.readableWidth, isWide: true) == nil)
    }

    /// A landscape Pro Max is 956 points across and keeps the phone's rows.
    @Test func aPhoneKeepsTheSystemMarginAtAnyWidth() {
        #expect(ReadableColumn.margin(in: 956, isWide: false) == nil)
        #expect(ReadableColumn.margin(in: 402, isWide: false) == nil)
    }

    /// The rows themselves, on a 13-inch iPad on its side.
    @Test func anIPadFormKeepsItsRowsInTheColumn() async throws {
        let defaults = try #require(UserDefaults(suiteName: "readable-column-snapshot"))
        defaults.removePersistentDomain(forName: "readable-column-snapshot")
        let store = TrackPreferencesStore(defaults: defaults)
        store.values.audioLanguageOverrides = ["en", "de"]
        store.values.channelLimit = .stereo
        try await Snapshot.verify(
            AudioSettingsView(trackPreferences: store)
                .environment(\.horizontalSizeClass, .regular)
                .environment(\.verticalSizeClass, .regular),
            named: "audio-settings-ipad",
            size: CGSize(width: 1376, height: 700)
        )
    }
}
#endif

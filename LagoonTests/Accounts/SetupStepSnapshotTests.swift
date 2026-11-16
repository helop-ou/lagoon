import SwiftUI
import Testing
@testable import Lagoon

/// What each step of the first sign-in's setup asks, without the screen
/// around it: the swimming jellyfish cannot be held still. Built on stores of
/// their own, since the shared ones are global and suites render in parallel.
@Suite("Setup step snapshots", .serialized)
@MainActor
struct SetupStepSnapshotTests {
    private func defaults() -> UserDefaults {
        let suite = "SetupStepSnapshotTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    /// Mid-September, so no season wears its theme over the chosen one.
    private static let september = Calendar(identifier: .gregorian).date(from: DateComponents(
        timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 9, day: 15, hour: 12
    ))!

    @Test func theLookStepListsTheThemesAndTheSeasonsSwitch() async throws {
        let store = ThemeStore(defaults: defaults(), now: { Self.september })
        store.configure(accountID: "viewer")
        store.select(.winter)

        try await verify(SetupLookStepView(store: store), named: "setup-look")
    }

    @Test func theLanguagesStepAsksForAudioAndSubtitles() async throws {
        let defaults = defaults()
        let tracks = TrackPreferencesStore(defaults: defaults)
        let subtitles = SubtitlePreferencesStore(defaults: defaults)
        tracks.configure(accountID: "viewer")
        subtitles.configure(accountID: "viewer")
        tracks.values.audioMode = .original
        tracks.values.subtitleMode = .always
        subtitles.setPrimaryLanguage("et")

        try await verify(
            SetupLanguagesStepView(trackPreferences: tracks, subtitlePreferences: subtitles),
            named: "setup-languages"
        )
    }

    @Test func lagoonsOwnSubtitleStyleShowsItsChoicesUnderTheSample() async throws {
        let subtitles = SubtitlePreferencesStore(defaults: defaults())
        subtitles.configure(accountID: "viewer")
        subtitles.values.followsSystemAppearance = false
        subtitles.values.textSize = .large
        subtitles.values.edgeStyle = .outline
        subtitles.values.background = .dark

        try await verify(SetupSubtitleLookStepView(subtitlePreferences: subtitles), named: "setup-subtitle-look")
    }

    @Test func theReportsStepSaysWhatAReportHolds() async throws {
        try await verify(SetupReportsStepView(), named: "setup-reports")
    }

    private func verify(_ step: some View, named name: String) async throws {
        // Over black: tvOS glass shifts over anything lighter.
        let framed = step
            .padding(Metrics.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
        try await Snapshot.verify(framed, named: name, size: Self.size)
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 760, height: 560)
        #else
        CGSize(width: 402, height: 430)
        #endif
    }
}

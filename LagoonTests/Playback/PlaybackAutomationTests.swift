import Foundation
import Testing
import LagoonEngine
@testable import Lagoon

/// Skip and Up Next timing, driven by the engine's clock rather than the
/// overlays, so it still runs on a locked phone.
@Suite("Playback automation")
@MainActor
struct PlaybackAutomationTests {
    private static let countdown: Duration = .milliseconds(40)
    /// Long enough after `countdown` to be sure nothing fired.
    private static let settled: Duration = .milliseconds(160)

    /// Wait for a countdown rather than sleeping past it: the main actor is
    /// shared with every suite, so a fixed sleep flakes under load.
    private func eventually(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func defaults(skip: SkipMode = .autoDelay, autoplay: AutoplayMode = .autoDelay) -> UserDefaults {
        let suite = "PlaybackAutomationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(skip.rawValue, forKey: SkipMode.defaultsKey)
        defaults.set(autoplay.rawValue, forKey: AutoplayMode.defaultsKey)
        return defaults
    }

    private func automation(
        skip: SkipMode = .autoDelay,
        autoplay: AutoplayMode = .autoDelay,
        segments: [MediaSegment] = [intro],
        nextUp: Bool = true
    ) -> PlaybackAutomation {
        let automation = PlaybackAutomation(
            defaults: defaults(skip: skip, autoplay: autoplay),
            countdown: Self.countdown
        )
        automation.beginItem(identity: "episode-1", segments: segments)
        automation.setNextUpAvailable(nextUp)
        return automation
    }

    nonisolated private static let intro = MediaSegment(id: "intro", kind: .intro, start: 10, end: 70)
    nonisolated private static let outro = MediaSegment(id: "outro", kind: .outro, start: 1_200, end: 1_320)

    // MARK: - Skip

    @Test func theCountdownSkipsOnItsOwn() async throws {
        let automation = automation()
        var landed: Double?
        automation.onSkip = { landed = $0.end }

        automation.tick(position: 5, duration: 1_320)
        #expect(automation.activeSegment == nil)
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        #expect(automation.skipTiming != nil)

        await eventually { landed == 70 }
        #expect(landed == 70)
        #expect(automation.activeSegment == nil)
        #expect(automation.skipTiming == nil)

        // Landing at the end must not re-arm the segment it just skipped.
        automation.tick(position: 69.9, duration: 1_320)
        #expect(automation.activeSegment == nil)
    }

    @Test func backDuringTheCountdownMeansNo() async throws {
        let automation = automation()
        var skipped = false
        automation.onSkip = { _ in skipped = true }

        automation.tick(position: 12, duration: 1_320)
        #expect(automation.dismissSkip())
        #expect(automation.activeSegment == nil)
        #expect(automation.skipTiming == nil)

        try await Task.sleep(for: Self.settled)
        #expect(!skipped)
        automation.tick(position: 30, duration: 1_320)
        #expect(automation.activeSegment == nil)
    }

    @Test func aScrubOutOfTheSegmentCancelsTheCountdown() async throws {
        let automation = automation()
        var skipped = false
        automation.onSkip = { _ in skipped = true }

        automation.tick(position: 12, duration: 1_320)
        automation.tick(position: 300, duration: 1_320)
        #expect(automation.activeSegment == nil)
        try await Task.sleep(for: Self.settled)
        #expect(!skipped)
    }

    // MARK: - Buffering

    /// The countdown runs on wall time, so it can come due during a stall,
    /// where seeking would spend the buffer the stall is waiting on.
    @Test func aSkipThatComesDueWhileBufferingWaits() async throws {
        let automation = automation()
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.isBuffering = true

        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        try await Task.sleep(for: Self.settled)
        #expect(landed == nil)
        // Only the seek is held.
        #expect(automation.activeSegment?.id == "intro")

        // Waited for: on a loaded run the countdown may not be due yet.
        automation.isBuffering = false
        await eventually { landed == 70 }
        #expect(landed == 70)
        #expect(automation.activeSegment == nil)
    }

    /// A held skip the playhead has passed would drag the viewer backwards.
    @Test func aHeldSkipIsDroppedOnceThePlayheadHasPassedIt() async throws {
        let automation = automation()
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.isBuffering = true

        automation.tick(position: 12, duration: 1_320)
        let timing = try #require(automation.skipTiming)
        await eventually { timing.progress(at: .now) == 1 }
        try await Task.sleep(for: Self.settled)
        automation.tick(position: 80, duration: 1_320)
        automation.isBuffering = false

        try await Task.sleep(for: Self.settled)
        #expect(landed == nil)
        #expect(automation.activeSegment == nil)
    }

    /// Select and a tap act now; only the clock waits.
    @Test func theViewerSkipsWhileBufferingAllTheSame() {
        let automation = automation(skip: .button)
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.isBuffering = true

        automation.tick(position: 12, duration: 1_320)
        automation.skip(Self.intro)
        #expect(landed == 70)
    }

    /// Instant mode is a countdown of zero, and waits on the same terms.
    @Test func instantModeWaitsForTheBufferToo() {
        let automation = automation(skip: .instant)
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.isBuffering = true

        automation.tick(position: 12, duration: 1_320)
        #expect(landed == nil)
        automation.isBuffering = false
        #expect(landed == 70)
    }

    @Test func instantModeSkipsOnEntry() {
        let automation = automation(skip: .instant)
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.tick(position: 12, duration: 1_320)
        #expect(landed == 70)
        #expect(automation.activeSegment == nil)
    }

    @Test func buttonModeWaitsForTheViewer() async throws {
        let automation = automation(skip: .button)
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        #expect(automation.skipTiming == nil)
        try await Task.sleep(for: Self.settled)
        #expect(landed == nil)

        automation.skip(Self.intro)
        #expect(landed == 70)
    }

    @Test func backDismissesTheButtonToo() {
        let automation = automation(skip: .button)
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.dismissSkip())
        #expect(automation.activeSegment == nil)
        #expect(landed == nil)
        // Answered for this segment, so it does not come back.
        automation.tick(position: 20, duration: 1_320)
        #expect(automation.activeSegment == nil)
    }

    @Test func instantModeHasNoPillForBackToDismiss() {
        let automation = automation(skip: .instant)
        automation.isBuffering = true
        // Held by the stall: the segment is active but nothing is drawn.
        automation.tick(position: 12, duration: 1_320)
        #expect(!automation.dismissSkip())
    }

    @Test func nothingArmsBeforeTheFirstTick() async throws {
        // A recap from zero must not arm on a new item's initial position,
        // or a slow open fires it before the clock ticks.
        let recap = MediaSegment(id: "recap", kind: .recap, start: 0, end: 40)
        let automation = automation(segments: [recap])
        var landed: Double?
        automation.onSkip = { landed = $0.end }
        #expect(automation.activeSegment == nil)
        try await Task.sleep(for: Self.settled)
        #expect(landed == nil)

        automation.tick(position: 630, duration: 1_320)
        #expect(automation.activeSegment == nil)
        automation.tick(position: 5, duration: 1_320)
        #expect(automation.activeSegment?.id == "recap")
    }

    @Test func thePanelSuppressesThePill() {
        let automation = automation()
        automation.isSuppressed = true
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment == nil)
        automation.isSuppressed = false
        #expect(automation.activeSegment?.id == "intro")
    }

    // MARK: - Up Next

    @Test func theCardCountsDownFromTheCreditsAndPlaysNext() async throws {
        let automation = automation(segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }

        automation.tick(position: 1_100, duration: 1_320)
        #expect(!automation.showsNextUp)
        #expect(automation.nextUpCardStart == 1_200)
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(automation.isCountingDown)
        #expect(automation.nextUpTiming != nil)

        await eventually { played }
        #expect(played)
    }

    @Test func withoutAnOutroTheCountdownIsPinnedToTheLastSeconds() async throws {
        let automation = automation()
        var played = false
        automation.onPlayNext = { played = true }

        automation.tick(position: 1_306, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(!automation.isCountingDown)
        try await Task.sleep(for: Self.settled)
        #expect(!played)

        automation.tick(position: 1_316, duration: 1_320)
        #expect(automation.isCountingDown)
        await eventually { played }
        #expect(played)
    }

    @Test func backOnTheCardStaysForTheRestOfTheEpisode() async throws {
        let automation = automation(segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }

        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.dismissNextUp())
        #expect(!automation.showsNextUp)
        #expect(!automation.isCountingDown)
        try await Task.sleep(for: Self.settled)
        #expect(!played)

        automation.tick(position: 1_300, duration: 1_320)
        #expect(!automation.showsNextUp)
        // Nor at the end of the file.
        #expect(!automation.autoplaysOnFinish)
    }

    @Test func cardModeOffersAndNeverActsAlone() async throws {
        let automation = automation(autoplay: .card, segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(!automation.isCountingDown)
        #expect(!automation.autoplaysOnFinish)
        try await Task.sleep(for: Self.settled)
        #expect(!played)
        automation.playNext()
        #expect(played)
    }

    @Test func backDismissesTheCardInCardModeToo() {
        let automation = automation(autoplay: .card, segments: [Self.intro, Self.outro])
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.dismissNextUp())
        #expect(!automation.showsNextUp)
        automation.tick(position: 1_300, duration: 1_320)
        #expect(!automation.showsNextUp)
    }

    @Test func nothingQueuedMeansNoCard() {
        let automation = automation(nextUp: false)
        automation.tick(position: 1_310, duration: 1_320)
        #expect(!automation.showsNextUp)
        #expect(automation.nextUpCardStart == nil)
        #expect(!automation.autoplaysOnFinish)
        automation.setNextUpAvailable(true)
        #expect(automation.showsNextUp)
        #expect(automation.autoplaysOnFinish)
    }

    @Test func theNextEpisodeStartsClean() async throws {
        let automation = automation(segments: [Self.intro, Self.outro])
        automation.tick(position: 12, duration: 1_320)
        automation.dismissSkip()
        automation.tick(position: 1_201, duration: 1_320)
        automation.dismissNextUp()

        automation.beginItem(identity: "episode-2", segments: [Self.intro, Self.outro])
        automation.setNextUpAvailable(true)
        #expect(!automation.nextUpDismissed)
        #expect(!automation.showsNextUp)
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.isCountingDown)
    }
}

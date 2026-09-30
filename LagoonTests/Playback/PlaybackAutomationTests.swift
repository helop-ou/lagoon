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
    private func eventually(_ condition: @MainActor () -> Bool) async {
        try? await Polling.untilMainActor(timeout: .seconds(3), pollInterval: .milliseconds(10), condition: condition)
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
        automation.beginItem(segments: segments)
        automation.setNextUpAvailable(nextUp)
        return automation
    }

    nonisolated private static let intro = MediaSegment(id: "intro", kind: .intro, start: 10, end: 70)
    nonisolated private static let outro = MediaSegment(id: "outro", kind: .outro, start: 1_200, end: 1_320)
    /// An ending song with a minute of scene after it, as anime often has.
    nonisolated private static let credits = MediaSegment(id: "credits", kind: .outro, start: 1_200, end: 1_260)

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

    // MARK: - Credits

    @Test func creditsWithASceneAfterThemCountDownToTheScene() async throws {
        let automation = automation(segments: [Self.intro, Self.credits])
        var landed: Double?
        automation.onSkip = { landed = $0.end }

        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.activeSegment?.id == "credits")
        #expect(SkipSegmentPolicy.title(for: Self.credits) == "Skip Credits")
        // Up Next waits for the end of the scene.
        #expect(!automation.showsNextUp)
        #expect(automation.nextUpCardStart == 1_305)

        await eventually { landed == 1_260 }
        #expect(landed == 1_260)
        automation.tick(position: 1_260, duration: 1_320)
        #expect(automation.activeSegment == nil)
        #expect(!automation.showsNextUp)
    }

    @Test func creditsFollowTheButtonAndInstantModes() async throws {
        let button = automation(skip: .button, segments: [Self.credits])
        var buttonLanded: Double?
        button.onSkip = { buttonLanded = $0.end }
        button.tick(position: 1_201, duration: 1_320)
        #expect(button.activeSegment?.id == "credits")
        #expect(button.skipTiming == nil)
        try await Task.sleep(for: Self.settled)
        #expect(buttonLanded == nil)
        #expect(button.dismissSkip())
        #expect(button.activeSegment == nil)

        let instant = automation(skip: .instant, segments: [Self.credits])
        var instantLanded: Double?
        instant.onSkip = { instantLanded = $0.end }
        instant.tick(position: 1_201, duration: 1_320)
        #expect(instantLanded == 1_260)
    }

    @Test func creditsThatRunToTheEndStillHandOffToUpNext() {
        // Ten seconds of black after the credits is no scene.
        let nearEnd = MediaSegment(id: "outro", kind: .outro, start: 1_200, end: 1_310)
        for segments in [[Self.outro], [nearEnd]] {
            let automation = automation(skip: .instant, segments: segments)
            var skipped = false
            automation.onSkip = { _ in skipped = true }
            automation.tick(position: 1_201, duration: 1_320)
            #expect(automation.activeSegment == nil)
            #expect(!skipped)
            #expect(automation.nextUpCardStart == 1_200)
            #expect(automation.showsNextUp)
        }
    }

    @Test func aNextEpisodePreviewAfterTheCreditsCountsAsCredits() {
        let preview = MediaSegment(id: "preview", kind: .preview, start: 1_262, end: 1_320)
        let automation = automation(segments: [Self.credits, preview])
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.activeSegment == nil)
        #expect(automation.nextUpCardStart == 1_200)
    }

    @Test func overlappingOrBackToBackOutrosCountAsOneRunOfCredits() {
        // Two providers, or credits delivered in parts, must not put the
        // pill over credits that run to the end.
        let layouts: [[MediaSegment]] = [
            [Self.credits, MediaSegment(id: "again", kind: .outro, start: 1_200, end: 1_320)],
            [Self.credits, MediaSegment(id: "rest", kind: .outro, start: 1_260, end: 1_320)],
            [MediaSegment(id: "early", kind: .outro, start: 1_190, end: 1_320), Self.credits],
        ]
        for segments in layouts {
            let automation = automation(skip: .button, segments: segments)
            automation.tick(position: 1_201, duration: 1_320)
            #expect(automation.activeSegment == nil, "\(segments.map(\.id))")
            #expect(automation.showsNextUp, "\(segments.map(\.id))")
        }
        // A real scene between two outros still earns the skip.
        let apart = [Self.credits, MediaSegment(id: "tag", kind: .outro, start: 1_300, end: 1_320)]
        let automation = automation(skip: .button, segments: apart)
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.activeSegment?.id == "credits")
        #expect(!automation.showsNextUp)
    }

    @Test func thePillAndTheCardNeverShareTheCorner() {
        // The shortest scene that still earns a skip.
        let credits = MediaSegment(id: "credits", kind: .outro, start: 1_200, end: 1_304)
        let automation = automation(skip: .button, segments: [credits])
        automation.tick(position: 1_303.9, duration: 1_320)
        #expect(automation.activeSegment?.id == "credits")
        #expect(!automation.showsNextUp)
        automation.tick(position: 1_305, duration: 1_320)
        #expect(automation.activeSegment == nil)
        #expect(automation.showsNextUp)
    }

    @Test func creditsWaitForTheDuration() {
        // Without a duration a scene after the credits cannot be told apart
        // from the end of the file.
        #expect(SkipSegmentPolicy.activeSegment(in: [Self.credits], at: 1_201, handled: [], duration: 0) == nil)
        #expect(SkipSegmentPolicy.endingCredits(in: [Self.credits], duration: 0) == nil)
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

    @Test func backOnTheCardMeansNotYetAndTheCardReturnsForTheLastSeconds() async throws {
        let automation = automation(segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }

        // Back at the credits: the viewer wants to watch them.
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.dismissNextUp())
        #expect(automation.nextUpAnswer == .notYet)
        #expect(!automation.showsNextUp)
        #expect(!automation.isCountingDown)
        try await Task.sleep(for: Self.settled)
        #expect(!played)

        automation.tick(position: 1_300, duration: 1_320)
        #expect(!automation.showsNextUp)
        // The end of the file still advances.
        #expect(automation.autoplaysOnFinish)

        // The last five seconds bring the card back, counting down.
        automation.tick(position: 1_315, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(automation.isCountingDown)
        #expect(automation.nextUpCardStart == 1_315)
        await eventually { played }
        #expect(played)
    }

    @Test func backDuringTheFinalCountdownStaysOnThisEpisode() async throws {
        let automation = automation(segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }

        automation.tick(position: 1_201, duration: 1_320)
        automation.dismissNextUp()
        automation.tick(position: 1_316, duration: 1_320)
        #expect(automation.isCountingDown)
        #expect(automation.dismissNextUp())
        #expect(automation.nextUpAnswer == .stay)
        #expect(!automation.showsNextUp)
        #expect(!automation.autoplaysOnFinish)
        try await Task.sleep(for: Self.settled)
        #expect(!played)
        automation.tick(position: 1_319, duration: 1_320)
        #expect(!automation.showsNextUp)
    }

    @Test func backFirstSeenInTheLastSecondsStays() {
        // No outro: the card appears 15 s out and counts down over the last 5.
        // A first Back inside those 5 s already answers the final countdown.
        let automation = automation()
        automation.tick(position: 1_317, duration: 1_320)
        #expect(automation.isCountingDown)
        #expect(automation.dismissNextUp())
        #expect(automation.nextUpAnswer == .stay)
        #expect(!automation.autoplaysOnFinish)
    }

    @Test func withoutAnOutroNotYetWaitsForTheLastSeconds() {
        let automation = automation()
        automation.tick(position: 1_306, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(automation.dismissNextUp())
        #expect(automation.nextUpAnswer == .notYet)
        automation.tick(position: 1_314, duration: 1_320)
        #expect(!automation.showsNextUp)
        automation.tick(position: 1_315, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(automation.isCountingDown)
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
        // Card mode never acts alone, so there is no "not yet" to come back to.
        #expect(automation.nextUpAnswer == .stay)
        #expect(!automation.showsNextUp)
        automation.tick(position: 1_316, duration: 1_320)
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

        automation.beginItem(segments: [Self.intro, Self.outro])
        automation.setNextUpAvailable(true)
        #expect(automation.nextUpAnswer == .none)
        #expect(!automation.showsNextUp)
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.isCountingDown)
    }
}

import Foundation
import Testing
@testable import Lagoon

/// Skip and Up Next timing off the engine's clock (HEL-176): the decisions
/// the overlays used to make in their own bodies, now made where a locked
/// phone can still reach them.
@Suite("Playback automation")
@MainActor
struct PlaybackAutomationTests {
    private static let countdown: Duration = .milliseconds(40)
    /// Long enough after `countdown` to be sure nothing fired.
    private static let settled: Duration = .milliseconds(160)

    /// A countdown that should fire is waited for, not slept past: the
    /// main actor is shared with every other suite in the run, so a fixed
    /// sleep after a 40 ms countdown is a flake under load.
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

    private static let intro = MediaSegment(id: "intro", kind: .intro, start: 10, end: 70)
    private static let outro = MediaSegment(id: "outro", kind: .outro, start: 1_200, end: 1_320)

    // MARK: - Skip

    @Test func theCountdownSkipsOnItsOwn() async throws {
        let automation = automation()
        var landed: Double?
        automation.onSkip = { landed = $0.end }

        automation.tick(position: 5, duration: 1_320)
        #expect(automation.activeSegment == nil)
        automation.tick(position: 12, duration: 1_320)
        #expect(automation.activeSegment?.id == "intro")
        #expect(automation.skipFill == 1)

        await eventually { landed == 70 }
        #expect(landed == 70)
        #expect(automation.activeSegment == nil)
        #expect(automation.skipFill == 0)

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
        #expect(automation.skipFill == 0)

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
        #expect(automation.skipFill == 0)
        #expect(!automation.dismissSkip())
        try await Task.sleep(for: Self.settled)
        #expect(landed == nil)

        automation.skip(Self.intro)
        #expect(landed == 70)
    }

    @Test func nothingArmsBeforeTheFirstTick() async throws {
        // A recap that covers zero must not arm from the phantom position
        // a new item starts at, or a slow open lets it fire before the
        // clock has ever ticked.
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
        #expect(automation.nextUpFill == 1)

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
        // The end of the file must not undo the answer either.
        #expect(!automation.autoplaysOnFinish)
    }

    @Test func cardModeOffersAndNeverActsAlone() async throws {
        let automation = automation(autoplay: .card, segments: [Self.intro, Self.outro])
        var played = false
        automation.onPlayNext = { played = true }
        automation.tick(position: 1_201, duration: 1_320)
        #expect(automation.showsNextUp)
        #expect(!automation.isCountingDown)
        #expect(!automation.dismissNextUp())
        #expect(!automation.autoplaysOnFinish)
        try await Task.sleep(for: Self.settled)
        #expect(!played)
        automation.playNext()
        #expect(played)
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

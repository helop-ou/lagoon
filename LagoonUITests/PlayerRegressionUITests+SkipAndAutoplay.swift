import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
    func testAutomaticIntroSkipUsesRealSegmentAndPlayerSeek() throws {
        let app = launchPlayer(
            title: "hardware-regression",
            series: "9-1-1",
            extraArguments: [
                "-debug.regressionFindSkippableEpisode", "YES",
                "-debug.regressionStartAtFirstSkippable", "YES",
                "-playback.skipMode", "autoDelay",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = state(in: app).double("skippableEnd")
        XCTAssertTrue(app.descendants(matching: .any)["player.skip"].waitForExistence(timeout: 4))
        waitForState(in: app, timeout: 12) { $0.double("time") >= end - 0.75 }
        XCTAssertFalse(app.descendants(matching: .any)["player.skip"].exists)
    }

    /// Back during the skip countdown means "no": the pill goes, the player
    /// stays open, and the countdown never seeks.
    func testMenuDuringSkipCountdownCancelsWithoutClosing() throws {
        let app = launchPlayer(
            title: "hardware-regression",
            series: "9-1-1",
            extraArguments: [
                "-debug.playerInputTrace", "YES",
                "-debug.regressionFindSkippableEpisode", "YES",
                "-debug.regressionStartAtFirstSkippable", "YES",
                "-playback.skipMode", "autoDelay",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = state(in: app).double("skippableEnd")
        let pill = app.descendants(matching: .any)["player.skip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        remote.press(.menu)

        XCTAssertTrue(pill.waitForNonExistence(timeout: 2), "Back left the skip pill up")
        // Past the 5 s countdown, the player is still open and never skipped.
        Thread.sleep(forTimeInterval: 6)
        let after = state(in: app)
        XCTAssertFalse(after.raw.isEmpty, "Back during the skip countdown closed the player")
        XCTAssertLessThan(after.double("time"), end - 1, "The cancelled countdown still skipped: \(after.raw)")
        XCTAssertEqual(after.int("paused"), 0)
    }

    /// Select on the pill skips at once and keeps playing; it must not fall
    /// through to play/pause.
    func testSelectOnSkipPillSkipsWithoutPausing() throws {
        let app = launchPlayer(
            title: "hardware-regression",
            series: "9-1-1",
            extraArguments: [
                "-debug.playerInputTrace", "YES",
                "-debug.regressionFindSkippableEpisode", "YES",
                "-debug.regressionStartAtFirstSkippable", "YES",
                // No countdown, so only Select can skip.
                "-playback.skipMode", "button",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = state(in: app).double("skippableEnd")
        let pill = app.descendants(matching: .any)["player.skip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        remote.press(.select)

        let skipped = waitForState(in: app, timeout: 8) { $0.double("time") >= end - 0.75 }
        XCTAssertEqual(skipped.int("paused"), 0, "Select on the skip pill paused: \(skipped.raw)")
        XCTAssertFalse(pill.exists)
    }

    /// "Ask Every Time" has no countdown, but Back still answers the pill
    /// before it closes the player.
    func testMenuDismissesTheAskSkipPillWithoutClosing() throws {
        let app = launchPlayer(
            title: "hardware-regression",
            series: "9-1-1",
            extraArguments: [
                "-debug.regressionFindSkippableEpisode", "YES",
                "-debug.regressionStartAtFirstSkippable", "YES",
                "-debug.playerInputTrace", "YES",
                "-playback.skipMode", "button",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = state(in: app).double("skippableEnd")
        let pill = app.descendants(matching: .any)["player.skip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 4))
        remote.press(.menu)

        XCTAssertTrue(pill.waitForNonExistence(timeout: 2), "Back left the Ask skip pill up")
        let after = state(in: app)
        XCTAssertFalse(after.raw.isEmpty, "Back on the Ask skip pill closed the player")
        XCTAssertLessThan(after.double("time"), end - 1, "Back on the Ask skip pill skipped: \(after.raw)")
        XCTAssertEqual(after.int("paused"), 0)

        // Answered: a second Back leaves.
        remote.press(.menu)
        XCTAssertTrue(
            app.descendants(matching: .any)["player.regression.state"].waitForNonExistence(timeout: 5),
            "A second Back did not close the player"
        )
    }

    /// Same rule for the Up Next card in "Ask Every Time".
    func testMenuDismissesTheAskUpNextCardWithoutClosing() throws {
        let app = launchPlayer(
            title: "Pilot",
            series: "9-1-1",
            extraArguments: [
                "-debug.regressionStartNearEnd", "YES",
                "-debug.playerInputTrace", "YES",
                "-playback.skipMode", "button",
                "-playback.autoplayMode", "card",
            ]
        )
        try requireRegressionFixture(in: app)
        let first = waitForState(in: app, timeout: 60) { $0.int("ready") == 1 && $0.int("nextUp") == 1 }
        remote.press(.menu)

        let after = waitForState(in: app, timeout: 3) { $0.int("nextUp") == 0 }
        XCTAssertEqual(after.string("item"), first.string("item"), "Back on the Ask card changed episode")
        XCTAssertEqual(after.int("paused"), 0)
    }

    /// The binge path: accept Up Next, then answer the successor's intro pill.
    /// 9-1-1's episodes open on an intro at 0 s.
    func testSkipPillAnswersAfterEpisodeHandoff() throws {
        let app = launchPlayer(
            title: "Pilot",
            series: "9-1-1",
            extraArguments: [
                "-debug.playerInputTrace", "YES",
                "-debug.regressionStartNearEnd", "YES",
                "-playback.skipMode", "autoDelay",
                "-playback.autoplayMode", "card",
            ]
        )
        try requireRegressionFixture(in: app)
        let first = waitForState(in: app, timeout: 60) { $0.int("ready") == 1 && $0.int("nextUp") == 1 }
        remote.press(.select)

        let successor = waitForState(in: app, timeout: 60) {
            $0.string("item") != first.string("item") && $0.int("ready") == 1
                && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = successor.double("skippableEnd")
        let pill = app.descendants(matching: .any)["player.skip"]
        XCTAssertTrue(pill.waitForExistence(timeout: 6), "No skip pill on the successor: \(successor.raw)")
        remote.press(.menu)
        XCTAssertTrue(pill.waitForNonExistence(timeout: 2), "Back left the successor's skip pill up")
        Thread.sleep(forTimeInterval: 6)
        let after = state(in: app)
        XCTAssertFalse(after.raw.isEmpty, "Back on the successor's skip pill closed the player")
        XCTAssertLessThan(after.double("time"), end - 1, "The cancelled countdown still skipped: \(after.raw)")
        XCTAssertEqual(after.int("paused"), 0, "Back on the successor's skip pill paused: \(after.raw)")
    }

    func testEpisodeHandoffKeepsSurfaceMountedAndStartsSuccessor() throws {
        let app = launchPlayer(
            title: "episode-handoff-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
                "-debug.regressionStartNearEnd", "YES",
                "-debug.regressionRendererRetirementDelaySeconds", "7",
                "-playback.autoplayMode", "card",
            ]
        )
        try requireRegressionFixture(in: app)
        let first = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && !$0.string("item").isEmpty
                && !$0.string("surface").isEmpty
        }
        let firstItemID = first.string("item")
        let firstSurfaceID = first.string("surface")
        XCTAssertEqual(first.string("method"), "DirectPlay")
        XCTAssertEqual(first.int("cache"), 1)

        // Without an Outro marker the card shows for the last 15 s.
        waitForState(in: app, timeout: 45) { $0.int("nextUp") == 1 }
        remote.press(.select)

        let transition = app.descendants(matching: .any)["player.episodeTransition"]
        XCTAssertFalse(
            transition.waitForExistence(timeout: 0.8),
            "A healthy episode handoff showed transition feedback immediately"
        )
        XCTAssertFalse(
            app.staticTexts["Starting next episode"].exists,
            "The countdown card was followed by redundant transition text"
        )
        XCTAssertTrue(
            transition.waitForExistence(timeout: 3),
            "The deliberately delayed handoff never exposed fallback progress feedback"
        )

        let deadline = Date().addingTimeInterval(45)
        var surfaceDisappeared = false
        var successor = RegressionState("")
        repeat {
            let probe = app.descendants(matching: .any)["player.regression.state"]
            if !probe.exists {
                surfaceDisappeared = true
            } else {
                successor = RegressionState(probe.value as? String ?? "")
                if successor.string("item") != firstItemID,
                   successor.int("ready") == 1,
                   successor.int("buffering") == 0,
                   successor.double("handoffMs") >= 0 {
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        XCTAssertNotEqual(successor.string("item"), firstItemID, "Successor episode never replaced the first")
        XCTAssertFalse(surfaceDisappeared, "The player surface disappeared during episode handoff")
        XCTAssertEqual(
            successor.string("surface"),
            firstSurfaceID,
            "Autoplay replaced the AVSampleBufferDisplayLayer instead of reusing it"
        )
        XCTAssertGreaterThanOrEqual(successor.double("handoffMs"), 0)
        XCTAssertLessThan(
            successor.double("handoffMs"),
            20_000,
            "Prepared episode handoff exceeded the hardware regression ceiling"
        )
        XCTAssertEqual(successor.int("engines"), 1)
        XCTAssertEqual(successor.int("controllers"), 1)
        XCTAssertEqual(successor.int("demux"), 1)
        XCTAssertEqual(successor.int("renderers"), 1)
        XCTAssertEqual(successor.int("unclean"), 0)
        XCTAssertEqual(successor.string("method"), "DirectPlay")
        XCTAssertEqual(successor.int("cache"), 1)
        XCTAssertFalse(transition.exists, "Transition progress remained over ready successor video")

        // First-frame readiness is not enough: a successor can start and
        // then starve repeatedly. Require sustained progress.
        let successorStartTime = successor.double("time")
        let successorStartStalls = successor.int("stalls")
        let successorStartMemory = successor.double("memoryMB")
        Thread.sleep(forTimeInterval: 20)
        let sustained = state(in: app)
        XCTAssertGreaterThan(
            sustained.double("time"),
            successorStartTime + 12,
            "Successor playback did not sustain media-clock progress"
        )
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(
            sustained.int("stalls") - successorStartStalls,
            1,
            "Successor entered a repeated stall/re-prime loop"
        )
        XCTAssertEqual(sustained.int("engines"), 1)
        XCTAssertEqual(sustained.int("demux"), 1)
        XCTAssertEqual(sustained.int("renderers"), 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
        XCTAssertLessThan(
            sustained.double("memoryMB"),
            successorStartMemory + 96,
            "Successor playback retained an excessive outgoing footprint"
        )
    }

    /// Automatic, hands off: the card counts down and the next episode
    /// starts on the same surface.
    func testAutomaticAutoplayRollsIntoTheNextEpisodeUnattended() throws {
        let (app, first) = try launchNearEndOfHandoffEpisode(autoplayMode: "autoDelay")
        let card = waitForState(in: app, timeout: 50) { $0.int("nextUp") == 1 }
        XCTAssertEqual(card.string("item"), first.string("item"))
        // Without an Outro marker the card shows for the last 15 s.
        XCTAssertGreaterThan(card.double("time"), card.double("duration") - 17, "Card came up too early: \(card.raw)")
        let handoff = waitForAutoplaySuccessor(in: app, after: first)
        assertAutoplaySuccessorIsHealthy(handoff, in: app, first: first)
    }

    /// Automatic, first Back means "not yet": the card returns for the last
    /// seconds and the episode still rolls on.
    func testAutomaticAutoplayNotYetStillRollsOn() throws {
        let (app, first) = try launchNearEndOfHandoffEpisode(autoplayMode: "autoDelay")
        let card = waitForState(in: app, timeout: 50) { $0.int("nextUp") == 1 }
        XCTAssertLessThan(
            card.double("time"),
            card.double("duration") - 6,
            "The card appeared inside the final countdown: \(card.raw)"
        )
        remote.press(.menu)
        let dismissed = waitForState(in: app, timeout: 3) { $0.int("nextUp") == 0 }
        XCTAssertEqual(dismissed.string("item"), first.string("item"), "Back on the card changed episode")
        XCTAssertEqual(dismissed.int("paused"), 0)
        let handoff = waitForAutoplaySuccessor(in: app, after: first)
        XCTAssertTrue(handoff.cardReturned, "The card did not return for the final countdown")
        assertAutoplaySuccessorIsHealthy(handoff, in: app, first: first)
    }

    /// Automatic, Back during the final countdown means "stay": the player
    /// closes at the end instead of rolling on.
    func testAutomaticAutoplayBackDuringFinalCountdownClosesAtTheEnd() throws {
        let (app, first) = try launchNearEndOfHandoffEpisode(autoplayMode: "autoDelay")
        waitForState(in: app, timeout: 50) { $0.int("nextUp") == 1 }
        remote.press(.menu)
        waitForState(in: app, timeout: 3) { $0.int("nextUp") == 0 }
        let returned = waitForState(in: app, timeout: 20) { $0.int("nextUp") == 1 }
        XCTAssertEqual(returned.string("item"), first.string("item"))
        XCTAssertGreaterThan(
            returned.double("time"),
            returned.double("duration") - 6,
            "The card returned before the final countdown: \(returned.raw)"
        )
        remote.press(.menu)
        assertPlayerClosesAtTheEndWithoutAdvancing(app, first: first)
    }

    /// An unanswered "Ask Every Time" card closes at the end like Off.
    func testUnansweredAskCardClosesAtTheEnd() throws {
        let (app, first) = try launchNearEndOfHandoffEpisode(autoplayMode: "card")
        waitForState(in: app, timeout: 50) { $0.int("nextUp") == 1 }
        assertPlayerClosesAtTheEndWithoutAdvancing(app, first: first)
    }

    func testAutoplayOffShowsNoCardAndClosesAtTheEnd() throws {
        let (app, first) = try launchNearEndOfHandoffEpisode(autoplayMode: "off")
        assertPlayerClosesAtTheEndWithoutAdvancing(app, first: first, forbidsCard: true)
    }

    private struct AutoplayHandoff {
        var successor = RegressionState("")
        var surfaceDisappeared = false
        var cardReturned = false
    }

    private func launchNearEndOfHandoffEpisode(
        autoplayMode: String
    ) throws -> (XCUIApplication, RegressionState) {
        let app = launchPlayer(
            title: "episode-handoff-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
                "-debug.regressionStartNearEnd", "YES",
                "-playback.skipMode", "button",
                "-playback.autoplayMode", autoplayMode,
            ]
        )
        try requireRegressionFixture(in: app)
        let first = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && !$0.string("item").isEmpty
                && !$0.string("surface").isEmpty
        }
        XCTAssertGreaterThan(
            first.double("time"),
            first.double("duration") - 60,
            "The fixture episode did not start near its end: \(first.raw)"
        )
        return (app, first)
    }

    /// Polls until another item is ready, noting whether the surface vanished
    /// and whether the card came back on the first item after going away.
    private func waitForAutoplaySuccessor(
        in app: XCUIApplication,
        after first: RegressionState,
        timeout: TimeInterval = 60
    ) -> AutoplayHandoff {
        var handoff = AutoplayHandoff()
        var cardWentAway = false
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let probe = app.descendants(matching: .any)["player.regression.state"]
            if probe.exists {
                let current = RegressionState(probe.value as? String ?? "")
                if current.string("item") == first.string("item") {
                    if current.int("nextUp") == 0 { cardWentAway = true }
                    if cardWentAway, current.int("nextUp") == 1 { handoff.cardReturned = true }
                } else if current.int("ready") == 1, current.int("buffering") == 0 {
                    handoff.successor = current
                    break
                }
            } else {
                handoff.surfaceDisappeared = true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return handoff
    }

    private func assertAutoplaySuccessorIsHealthy(
        _ handoff: AutoplayHandoff,
        in app: XCUIApplication,
        first: RegressionState
    ) {
        let successor = handoff.successor
        XCTAssertFalse(successor.string("item").isEmpty, "No successor became ready")
        XCTAssertNotEqual(successor.string("item"), first.string("item"))
        XCTAssertFalse(handoff.surfaceDisappeared, "The player surface disappeared during the handoff")
        XCTAssertEqual(
            successor.string("surface"),
            first.string("surface"),
            "Autoplay replaced the AVSampleBufferDisplayLayer instead of reusing it"
        )
        XCTAssertEqual(successor.int("nextUp"), 0, "Up Next stayed up over the successor")
        XCTAssertEqual(successor.int("paused"), 0, "The successor started paused")
        XCTAssertGreaterThanOrEqual(successor.double("handoffMs"), 0)
        XCTAssertLessThan(successor.double("handoffMs"), 20_000)
        XCTAssertEqual(successor.int("engines"), 1)
        XCTAssertEqual(successor.int("controllers"), 1)
        XCTAssertEqual(successor.int("demux"), 1)
        XCTAssertEqual(successor.int("renderers"), 1)
        XCTAssertEqual(successor.int("unclean"), 0, successor.raw)

        let startTime = successor.double("time")
        let startStalls = successor.int("stalls")
        Thread.sleep(forTimeInterval: 15)
        let sustained = state(in: app)
        XCTAssertEqual(sustained.string("item"), successor.string("item"))
        XCTAssertGreaterThan(
            sustained.double("time"),
            startTime + 10,
            "Successor playback did not sustain media-clock progress: \(sustained.raw)"
        )
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(sustained.int("stalls") - startStalls, 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
    }

    private func assertPlayerClosesAtTheEndWithoutAdvancing(
        _ app: XCUIApplication,
        first: RegressionState,
        forbidsCard: Bool = false
    ) {
        let probe = app.descendants(matching: .any)["player.regression.state"]
        let deadline = Date().addingTimeInterval(70)
        var closed = false
        var sawCard = false
        var last = RegressionState("")
        repeat {
            // The player closes under this loop, and reading `value` after
            // `exists` fails the test when it goes in between. A snapshot
            // throws instead. Its value is truncated, but `item` and `nextUp`
            // come first.
            guard let snapshot = try? probe.snapshot() else {
                closed = true
                break
            }
            last = RegressionState(snapshot.value as? String ?? "")
            XCTAssertEqual(last.string("item"), first.string("item"), "Advanced to another item: \(last.raw)")
            if last.int("nextUp") == 1 { sawCard = true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTAssertTrue(closed, "The player did not close at the end: \(last.raw)")
        if forbidsCard {
            XCTAssertFalse(sawCard, "Autoplay Off showed the Up Next card")
        }
        // Nothing reopens the next episode behind the viewer's back.
        Thread.sleep(forTimeInterval: 5)
        XCTAssertFalse(probe.exists, "The player reopened after closing")
    }
}

#endif

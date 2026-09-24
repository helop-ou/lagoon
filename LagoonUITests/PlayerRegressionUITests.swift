import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

final class PlayerRegressionUITests: PlayerUITestCase {
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlaybackPauseScrubTracksAndSubtitles() throws {
        // H.264 with real subtitle tracks, so the simulator can seek both
        // ways without waiting on an HEVC transcode.
        let app = launchPlayer(title: "Pilot", series: "Young Sheldon")
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { value in
            value.int("ready") == 1 && value.int("audioCount") > 0
        }

        let startingTime = state(in: app).double("time")
        waitForState(in: app, timeout: 8) { $0.double("time") > startingTime + 2 }

        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
        let pausedTime = state(in: app).double("time")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(abs(state(in: app).double("time") - pausedTime), 0.8)

        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }

        let beforeScrub = state(in: app).double("time")
        remote.press(.right)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        XCTAssertTrue(app.descendants(matching: .any)["player.scrub.chip"].exists)
        XCTAssertGreaterThan(state(in: app).int("chapters"), 0)
        XCTAssertEqual(state(in: app).int("trickplay"), 1)

        // Keep the scrub open while the authenticated trickplay sheet loads.
        for _ in 0..<4 {
            if state(in: app).int("trickplayFrame") == 1 { break }
            Thread.sleep(forTimeInterval: 0.35)
            remote.press(.right)
        }
        waitForState(in: app, timeout: 8) { $0.int("trickplayFrame") == 1 }
        remote.press(.select)
        // The server may still be generating the simulator's HLS rendition;
        // wait for the re-prime rather than treating it as a bad seek.
        waitForState(in: app, timeout: 30) {
            $0.int("scrubbing") == 0
                && $0.int("buffering") == 0
                && $0.double("time") > beforeScrub + 5
        }

        let afterForwardScrub = state(in: app).double("time")
        remote.press(.left)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        remote.press(.select)
        waitForState(in: app, timeout: 30) {
            $0.int("scrubbing") == 0
                && $0.int("buffering") == 0
                && $0.double("time") < afterForwardScrub - 5
        }

        exerciseSubtitles(in: app)
    }

    /// Drives the viewer's route: down into the panel, across to Video,
    /// down onto the speed steppers.
    func testPlaybackSpeedIsChosenFromTheVideoTab() throws {
        let app = launchPlayer(title: "The Great Train Robbery", simulatorTranscode: false)
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 }
        XCTAssertEqual(state(in: app).string("rate"), "1")

        remote.press(.down)
        waitForState(in: app, timeout: 5) { $0.int("panel") == 1 }
        // `panel=1` lands 225 ms before the panel claims focus, and a Right
        // inside that window is swallowed, so retry until the tab changes.
        pressUntil(tab: "video", in: app, press: .right)

        remote.press(.down)
        for control in ["decrease", "value", "increase"] {
            let element = app.descendants(matching: .any)["player.playbackRate.\(control)"]
            XCTAssertTrue(
                element.waitForExistence(timeout: 5),
                "the Video tab should offer the speed \(control)"
            )
        }

        let decrease = app.buttons["player.playbackRate.decrease"]
        let increase = app.buttons["player.playbackRate.increase"]
        XCTAssertTrue(
            waitForFocus(decrease),
            "Down from the Video tab should land on the speed minus button"
        )
        remote.press(.select)
        let lowered = waitForState(in: app, timeout: 8) { $0.string("rate") == "0.75" }
        XCTAssertEqual(lowered.string("rate"), "0.75", "minus should step down one value")

        remote.press(.right)
        XCTAssertTrue(
            waitForFocus(increase),
            "Right from minus should cross the value label onto plus"
        )
        remote.press(.select)
        let restored = waitForState(in: app, timeout: 8) { $0.string("rate") == "1" }
        XCTAssertEqual(restored.string("rate"), "1", "plus should step back up")

        remote.press(.select)
        let raised = waitForState(in: app, timeout: 8) { $0.string("rate") == "1.25" }
        XCTAssertEqual(raised.string("rate"), "1.25", "plus should step past the default")

        // After Menu closes the panel, the arrows must scrub again.
        remote.press(.menu)
        waitForState(in: app, timeout: 5) { $0.int("panel") == 0 }
        remote.press(.right)
        let scrubbing = waitForState(in: app, timeout: 5) { $0.int("scrubbing") == 1 }
        XCTAssertEqual(scrubbing.int("scrubbing"), 1, "the surface must still own the arrows")
    }

    func testRepeatedBufferedScrubbingRecoversAndPreservesPlaybackState() throws {
        let app = launchPlayer(
            title: "buffered-scrub-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.string("method") == "DirectPlay"
                && $0.int("cache") == 1
        }
        let initialStalls = initial.int("stalls")
        let initialMemory = initial.double("memoryMB")
        let initialBuffered = initial.double("buffered")
        let initialPlayheadPrefetches = initial.int("playheadPrefetches")

        // A self-committing nudge while paused must seek without resuming.
        // An explicit Select commit is a different path and does resume.
        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
        let pausedOrigin = state(in: app).double("time")
        remote.press(.right)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        let pausedLanding = waitForState(in: app, timeout: 8) {
            $0.int("scrubbing") == 0
                && $0.int("buffering") == 0
                && $0.int("paused") == 1
                && $0.double("lastScrub") > pausedOrigin + 5
        }
        XCTAssertLessThan(
            abs(pausedLanding.double("time") - pausedLanding.double("lastScrub")),
            2
        )
        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }

        // Long seeks both ways hit sparse-cache holes, renderer re-prime and
        // scrub acceleration. Every landing must leave the clock moving.
        for cycle in 1...3 {
            let forwardOrigin = state(in: app).double("time")
            for _ in 0..<6 { remote.press(.right) }
            waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
            remote.press(.select)
            let forward = waitForState(in: app, timeout: 30) {
                $0.int("scrubbing") == 0
                    && $0.int("buffering") == 0
                    && $0.double("time") > forwardOrigin + 45
            }
            let forwardLanding = forward.double("time")
            waitForState(in: app, timeout: 8) { $0.double("time") > forwardLanding + 1 }
            if cycle == 1 {
                // Proves the live cache writer follows FFmpeg's post-seek
                // byte position while keeping the byte-zero prefix.
                remote.press(.playPause)
                waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
                waitForState(in: app, timeout: 35) {
                    $0.int("playheadPrefetches") > initialPlayheadPrefetches
                        && $0.int("bufferRanges") >= 2
                }
                remote.press(.playPause)
                waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }
            }

            for _ in 0..<4 { remote.press(.left) }
            waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
            remote.press(.select)
            let backward = waitForState(in: app, timeout: 30) {
                $0.int("scrubbing") == 0
                    && $0.int("buffering") == 0
                    && $0.double("time") < forwardLanding - 20
            }
            let backwardLanding = backward.double("time")
            waitForState(in: app, timeout: 8) { $0.double("time") > backwardLanding + 1 }

            XCTAssertLessThanOrEqual(
                state(in: app).int("stalls") - initialStalls,
                1,
                "Repeated seek cycle \(cycle) accumulated unexpected stalls"
            )
        }

        let final = state(in: app)
        XCTAssertEqual(final.int("buffering"), 0)
        XCTAssertEqual(final.int("engines"), 1)
        XCTAssertEqual(final.int("demux"), 1)
        XCTAssertEqual(final.int("renderers"), 1)
        XCTAssertEqual(final.int("unclean"), 0)
        XCTAssertGreaterThanOrEqual(final.double("buffered"), initialBuffered)
        XCTAssertGreaterThan(final.int("playheadPrefetches"), initialPlayheadPrefetches)
        XCTAssertGreaterThanOrEqual(final.int("bufferRanges"), 2)
        XCTAssertLessThan(final.double("memoryMB"), initialMemory + 96)
    }

    func testRealAudioTrackSwitchReprimesPlayback() throws {
        // Any direct-play H.264 item with several audio tracks: the
        // simulator can decode it and no private title is hard-coded.
        let app = launchPlayer(
            title: "multi-audio-regression",
            extraArguments: ["-debug.regressionFindMultiAudioH264", "YES"]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1 && $0.int("audioCount") > 1
        }
        exerciseAudioTracks(in: app)
    }

    func testAudioRouteFlushAndMediaServicesResetRecoverWithoutAutomaticResume() throws {
        let app = launchPlayer(
            title: "audio-lifecycle-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionInjectAudioRendererFlush", "YES",
                "-debug.regressionInjectMediaServicesReset", "YES",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.int("audioCount") > 0
        }
        let initialTime = initial.double("time")

        let afterFlush = waitForState(in: app, timeout: 30) {
            $0.int("audioRecoveries") == 1
                && $0.int("buffering") == 0
                && $0.int("paused") == 0
        }
        XCTAssertGreaterThan(afterFlush.double("time"), initialTime)

        let afterReset = waitForState(in: app, timeout: 30) {
            $0.int("mediaResetRecoveries") == 1
                && $0.int("buffering") == 0
                && $0.int("paused") == 1
        }
        let pausedTime = afterReset.double("time")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(abs(state(in: app).double("time") - pausedTime), 0.8)

        remote.press(.playPause)
        let resumed = waitForState(in: app, timeout: 8) {
            $0.int("paused") == 0 && $0.double("time") > pausedTime + 1
        }
        XCTAssertEqual(resumed.int("engines"), 1)
        XCTAssertEqual(resumed.int("demux"), 1)
        XCTAssertEqual(resumed.int("renderers"), 1)
        XCTAssertEqual(resumed.int("unclean"), 0)
    }

    func testRendererSideAudioStarvationIsDetectedAndRecovers() throws {
        let app = launchPlayer(
            title: "audio-starvation-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionRequireAudio", "YES",
                "-debug.simulateAudioStarvation", "YES",
                "-debug.starvationInjectionDelaySeconds", "8",
                "-debug.starvationInjectionDurationSeconds", "5",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
        }
        let initialDry = initial.int("aDry")
        let initialIdleRequests = initial.int("idleRequests")

        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(
            state(in: app).int("aDry"),
            initialDry,
            "Healthy playback reported renderer starvation before the injection"
        )

        let held = waitForState(in: app, timeout: 15) { $0.int("audioHeld") == 1 }
        let heldAt = held.double("time")
        let dry = waitForState(in: app, timeout: 8) {
            $0.int("aDry") == initialDry + 1
                && $0.double("audioLead") < 0.25
        }
        XCTAssertGreaterThan(
            dry.double("time"),
            heldAt + 0.5,
            "Withholding audio unexpectedly stopped the video clock"
        )
        XCTAssertEqual(dry.int("deliveryHeld"), 0)

        let recovered = waitForState(in: app, timeout: 12) {
            $0.int("audioHeld") == 0
                && $0.double("audioLead") > 0.25
                && $0.int("buffering") == 0
        }
        XCTAssertEqual(recovered.int("aDry"), initialDry + 1)
        XCTAssertLessThanOrEqual(recovered.int("videoMax"), recovered.int("videoHard"))
        XCTAssertLessThan(
            recovered.int("idleRequests") - initialIdleRequests,
            100,
            "The held audio pump reintroduced an empty request-block spin"
        )
    }

    /// With audio buffering on, withheld audio stops the clock after the
    /// confirmation delay, counts as an audio stall, and playback resumes
    /// once the renderer has its lead back.
    func testAudioStarvationBuffersWhenTheModeIsOn() throws {
        let app = launchPlayer(
            title: "audio-starvation-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionRequireAudio", "YES",
                "-debug.simulateAudioStarvation", "YES",
                "-debug.starvationInjectionDelaySeconds", "8",
                // The renderer holds 2-3 s of audio, so the stall confirms
                // near 3.5 s. A 7 s hold leaves a ~3.5 s stall, under the 5 s
                // reprime rule, so the no-reprime assertion below runs.
                "-debug.starvationInjectionDurationSeconds", "7",
                "-debug.bufferOnAudioStarvation", "YES",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
                && $0.int("audioBuffers") == 1
        }
        let initialStalls = initial.int("stalls")
        let initialAudioStalls = initial.int("audioStalls")
        let initialDry = initial.int("aDry")
        let initialReprimes = initial.int("reprimes")

        _ = waitForState(in: app, timeout: 15) { $0.int("audioHeld") == 1 }
        let buffering = waitForState(in: app, timeout: 9) { $0.int("buffering") == 1 }
        let stallBegan = Date()
        XCTAssertEqual(buffering.int("aDry"), initialDry + 1)

        _ = waitForState(in: app, timeout: 12) { $0.int("audioHeld") == 0 }
        let stallReleased = Date()
        let recovered = waitForState(in: app, timeout: 20) {
            $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
                && $0.double("time") > buffering.double("time") + 0.5
        }
        // Report every counter on failure: which moved shows the recovery path.
        continueAfterFailure = true
        XCTAssertEqual(recovered.int("stalls"), initialStalls + 1, recovered.raw)
        XCTAssertEqual(recovered.int("audioStalls"), initialAudioStalls + 1, recovered.raw)
        XCTAssertEqual(recovered.int("aDry"), initialDry + 1, recovered.raw)
        XCTAssertLessThanOrEqual(recovered.int("videoMax"), recovered.int("videoHard"), recovered.raw)

        let confirmedStallSeconds = stallReleased.timeIntervalSince(stallBegan)
        print("AudioBufferingProbe confirmedStall=\(confirmedStallSeconds) \(recovered.raw)")
        if confirmedStallSeconds < 4 {
            XCTAssertEqual(
                recovered.int("reprimes"),
                initialReprimes,
                "A stall of \(confirmedStallSeconds)s should have refilled in place rather than falling back to a seek: \(recovered.raw)"
            )
        }
        // A longer stall may take the seek fallback; that is not pinned.
    }

    /// A demux outage longer than the video cushion buffers, then resumes
    /// within the video hard limit. The seek fallback is asserted absent
    /// only when the stall was clearly under the 5 s rule.
    func testBoundedDeliveryOutageRecoversThroughStallWithoutReprime() throws {
        let app = launchPlayer(
            title: "delivery-stall-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionRequireAudio", "YES",
                // A transcode never reaches the held state in time.
                "-debug.regressionRequireDirectPlay", "YES",
                "-debug.simulateDeliveryStall", "YES",
                "-debug.starvationInjectionDelaySeconds", "8",
                // Direct play coasts on up to 120 queued frames (~5 s at
                // 24 fps) plus a 1 s confirmation, so the hold must outlast
                // that. A decoded path (30 frames) may cross the 5 s reprime
                // rule, hence the conditional assertion below.
                "-debug.starvationInjectionDurationSeconds", "8",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
                && $0.int("videoHard") > 0
        }
        let initialReprimes = initial.int("reprimes")
        let held = waitForState(in: app, timeout: 15) { $0.int("deliveryHeld") == 1 }
        _ = waitForState(in: app, timeout: 9) { $0.int("buffering") == 1 }
        let stallBegan = Date()

        _ = waitForState(in: app, timeout: 12) { $0.int("deliveryHeld") == 0 }
        let stallReleased = Date()
        let recovered = waitForState(in: app, timeout: 20) {
            $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
                && $0.double("time") > held.double("time") + 0.5
        }
        let confirmedStallSeconds = stallReleased.timeIntervalSince(stallBegan)
        if confirmedStallSeconds < 4 {
            XCTAssertEqual(
                recovered.int("reprimes"),
                initialReprimes,
                "A stall of \(confirmedStallSeconds)s should have refilled in place rather than falling back to a seek"
            )
        }
        XCTAssertLessThanOrEqual(
            recovered.int("videoMax"),
            recovered.int("videoHard"),
            "Recovery exceeded the active video-memory bound"
        )
        XCTAssertEqual(recovered.int("audioHeld"), 0)
    }

    /// An HLS fragment's `mdat` holds all its video, then all its audio. A
    /// demuxer that stops at the decoded video limit reaches the audio late
    /// and starves the renderer once per fragment (see the engine's
    /// docs/reference/queues-and-renderers.md, "HLS packet order and the
    /// video intake").
    /// Read-ahead video parks in an intake queue so the demuxer reaches the
    /// audio. Forces the remux rung, then checks 40 s of playback stays
    /// inside both bounds with no new dry episode, stall or reprime.
    func testForcedRemuxKeepsAudioFedWithinTheIntakeBound() throws {
        // Mirrors `DemuxBackpressurePolicy.videoIntakeHardLimit`; the UI
        // test target cannot import the app, so keep the two in sync.
        let videoIntakeHardLimit = 600

        let app = launchPlayer(
            title: "hls-remux-intake-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionRequireAudio", "YES",
                "-debug.regressionFailFirstDelivery", "delivery",
                "-playback.autoplayMode", "off",
                // An intro auto-skip would seek mid-run.
                "-playback.skipMode", "button",
            ]
        )
        try requireRegressionFixture(in: app)
        _ = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
        }

        // The injected failure fires 4 s in and steps down to remux. Wait on
        // `rung`, not `method`: Jellyfin reports `Transcode` for remux too.
        // The remux rung can take 10-20 s to come up.
        let fallenBack = waitForState(in: app, timeout: 60) {
            $0.string("rung") == "remux"
                && $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("audioLead") > 0.25
        }

        // The switch itself may count a dry episode, so baseline after it.
        let baselineDry = fallenBack.int("aDry")
        let baselineStalls = fallenBack.int("stalls")
        let baselineReprimes = fallenBack.int("reprimes")

        var observedHealthyLead = false
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 1)
            let sample = state(in: app)
            XCTAssertEqual(
                sample.int("buffering"),
                0,
                "Remux playback buffered while the demux read past the decoded video limit: \(sample.raw)"
            )
            XCTAssertLessThanOrEqual(
                sample.int("videoMax"),
                sample.int("videoHard"),
                "Decoded video backlog exceeded its hard limit during remux playback: \(sample.raw)"
            )
            XCTAssertLessThanOrEqual(
                sample.int("videoIntakeMax"),
                videoIntakeHardLimit,
                "Intake queue exceeded DemuxBackpressurePolicy.videoIntakeHardLimit: \(sample.raw)"
            )
            if sample.double("audioLead") > 0.25 { observedHealthyLead = true }
        }

        let final = state(in: app)
        XCTAssertTrue(
            observedHealthyLead,
            "Audio lead never rose back above the floor during 40 s of remux playback: \(final.raw)"
        )
        XCTAssertEqual(
            final.int("aDry"),
            baselineDry,
            "Remux playback starved the audio renderer during 40 s of interleaved fMP4 fragments: \(final.raw)"
        )
        XCTAssertEqual(
            final.int("stalls"),
            baselineStalls,
            "Remux playback stalled during the 40 s intake-bound window: \(final.raw)"
        )
        XCTAssertEqual(
            final.int("reprimes"),
            baselineReprimes,
            "Remux playback reprimed during the 40 s intake-bound window: \(final.raw)"
        )
    }

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

    func testRealSubtitleCueReachesThePlayerOverlay() throws {
        let app = launchPlayer(title: "Pilot", series: "Young Sheldon")
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.int("subtitleCount") > 0
        }
        // The caption default may be Off, so pick the first track explicitly.
        if state(in: app).int("subtitle") == 0 {
            selectFirstSubtitle(in: app)
        }
        waitForState(in: app, timeout: 60) { $0.int("subtitleVisible") == 1 }
        XCTAssertTrue(
            app.descendants(matching: .any)["player.subtitle.text"].exists
                || app.descendants(matching: .any)["player.subtitle.image"].exists
        )
    }

    /// An external track is the only subtitle switch that loads a file
    /// first, so the only one that can hang on "Loading …".
    ///
    /// Round trip: external → Off → embedded → the same external track.
    /// A stale cancel token or spent one-shot task only shows on the
    /// second load of the same track.
    func testExternalSubtitleTrackLoadsSwitchesAndClears() throws {
        // Top Gear S1E1 on the fixture server: 576p H.264, one embedded and
        // one external SubRip track. The device profile is deliberate: it is
        // what an Apple TV negotiates, and under it the server converts the
        // sidecar to WebVTT.
        let app = launchPlayer(title: "Episode 1", series: "Top Gear", simulatorTranscode: false)
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.int("subtitleCount") > 0
        }
        let started = state(in: app).double("time")
        waitForState(in: app, timeout: 15) { $0.double("time") > started + 1.5 }

        openSubtitleTab(in: app)
        let rows = subtitleTrackRows(in: app)
        guard let externalRow = rows.first(where: { $0.label.contains("External") })?.identifier
            .replacingOccurrences(of: "player.track.", with: ""),
            let externalOrdinal = Int(externalRow.dropFirst("subtitle-".count)) else {
            XCTFail("""
                The fixture item must expose an external subtitle track. \
                Rows: \(rows.map { "\($0.identifier)=\($0.label)" }). \
                State: \(state(in: app).raw)
                """)
            return
        }
        let embeddedRow = rows.first {
            $0.identifier != "player.track.subtitle-off" && !$0.label.contains("External")
                && !$0.label.contains("Downloaded")
        }?.identifier.replacingOccurrences(of: "player.track.", with: "")
        print("""
            ExternalSubtitleRegression rows=\(rows.map { "\($0.identifier)=\($0.label)" }) \
            external=\(externalRow) embedded=\(embeddedRow ?? "none") \
            state=\(state(in: app).raw)
            """)

        selectTrackRow(externalRow, in: app)
        assertSubtitleLoadFinishes(ordinal: externalOrdinal, in: app, stage: "first external load")
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        waitForSubtitleCue(in: app, stage: "first external load")

        // Off must clear the cue and leave no load behind it.
        openSubtitleTab(in: app)
        selectTrackRow("subtitle-off", in: app)
        let cleared = waitForState(in: app, timeout: 8) {
            $0.int("subtitle") == 0 && $0.int("subtitleVisible") == 0
        }
        XCTAssertEqual(cleared.string("subtitleLoad"), "idle", "Off left a subtitle load running")
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        XCTAssertFalse(
            app.staticTexts["player.subtitle.text"].exists,
            "Off must remove the cue that the external track was showing"
        )

        if let embeddedRow, let embeddedOrdinal = Int(embeddedRow.dropFirst("subtitle-".count)) {
            openSubtitleTab(in: app)
            selectTrackRow(embeddedRow, in: app)
            // An embedded switch commits without a load.
            let embedded = waitForState(in: app, timeout: 30) {
                $0.int("subtitle") == embeddedOrdinal && $0.int("buffering") == 0
            }
            XCTAssertEqual(
                embedded.string("subtitleLoad"), "idle",
                "an embedded track must not enter the external load state"
            )
            remote.press(.menu)
            waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
            waitForSubtitleCue(in: app, stage: "embedded track")
        }

        openSubtitleTab(in: app)
        selectTrackRow(externalRow, in: app)
        assertSubtitleLoadFinishes(ordinal: externalOrdinal, in: app, stage: "second external load")
        let reloaded = XCTAttachment(screenshot: app.screenshot())
        reloaded.name = "External subtitle reselected"
        reloaded.lifetime = .keepAlways
        add(reloaded)
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        waitForSubtitleCue(in: app, stage: "second external load")

        let end = state(in: app)
        XCTAssertEqual(end.int("paused"), 0, "subtitle switching must not pause playback")
        waitForState(in: app, timeout: 12) { $0.double("time") > end.double("time") + 1 }
    }

    /// Downloading a subtitle attaches it to the item, and Jellyfin then
    /// renumbers the streams, so the next switch could hand the demuxer the
    /// wrong index and stall. Asserts the playhead keeps moving, before and
    /// after a relaunch.
    ///
    /// Needs `scripts/jellyfin-regression-fixture.py --subtitle-provider`.
    func testDownloadedSubtitleThenEmbeddedSwitchKeepsPlaying() throws {
        guard let address = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              let server = URL(string: address), server.host == "127.0.0.1" else {
            throw XCTSkip("Requires the synthetic subtitle provider fixture")
        }
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.benchSearchTerm", "Session fixture movie",
            "-debug.regressionFindPlayable", "YES",
            "-playback.autoplayMode", "off",
        ]
        app.launchEnvironment = [
            "LAGOON_REGRESSION_SERVER": address,
            "LAGOON_REGRESSION_USER": "Fixture viewer",
            "LAGOON_REGRESSION_PASS": "",
        ]
        app.launch()
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 }

        openSubtitleTab(in: app)
        let embeddedCount = subtitleTrackRows(in: app).count - 1
        XCTAssertGreaterThan(
            embeddedCount, 0,
            "the provider fixture must carry an embedded track to switch back to"
        )

        selectTrackRow("subtitle-search", in: app)
        let result = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "player.subtitleResult.")
        ).firstMatch
        guard result.waitForExistence(timeout: 20) else {
            throw XCTSkip("The fixture provider returned no candidates")
        }
        let resultID = result.identifier.replacingOccurrences(of: "player.subtitleResult.", with: "")
        selectTrackRow("subtitle-result-\(resultID)", in: app)

        // The new track is selected and numbered after the existing ones.
        let downloadedOrdinal = embeddedCount + 1
        let downloaded = waitForState(in: app, timeout: 40) {
            $0.int("subtitleCount") > embeddedCount && $0.int("subtitle") == downloadedOrdinal
        }
        XCTAssertEqual(
            downloaded.string("subtitleLoad"), "idle",
            "the downloaded track must not leave the panel loading"
        )
        XCTAssertTrue(
            subtitleTrackRows(in: app).contains { $0.label.contains("Downloaded") },
            "the downloaded track must be listed as one"
        )
        remote.press(.menu)
        waitForState(in: app, timeout: 6) { $0.int("panel") == 0 }
        waitForSubtitleCue(in: app, stage: "downloaded track")

        assertEmbeddedSwitchKeepsPlaying(in: app, stage: "after download")

        // A fresh session sees the renumbered stream list.
        app.terminate()
        app.launch()
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 }
        openSubtitleTab(in: app)
        let rows = subtitleTrackRows(in: app)
        XCTAssertTrue(
            rows.contains { $0.label.contains("External") },
            "the attached sidecar must come back as an external track: \(rows.map(\.label))"
        )
        remote.press(.menu)
        waitForState(in: app, timeout: 6) { $0.int("panel") == 0 }
        assertEmbeddedSwitchKeepsPlaying(in: app, stage: "after relaunch")
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

    func testCachedHLSPlaybackCrossesSegmentBoundariesWithoutStalling() throws {
        let app = launchPlayer(
            title: "cached-hls-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.experimentalPlaybackCache", "YES",
                // Start on remux so the demo, where everything direct-plays,
                // still serves real HLS.
                "-debug.regressionInitialDelivery", "remux",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("time") >= 0
        }
        try requireNegotiatedTranscode(initial)
        let startTime = initial.double("time")
        let startStalls = initial.int("stalls")
        let startMemory = initial.double("memoryMB")
        XCTAssertEqual(initial.int("cache"), 1)

        // 15 s crosses several short fMP4 segments, each an HLS open/close
        // that reuses a keep-alive connection.
        Thread.sleep(forTimeInterval: 15)
        let sustained = state(in: app)
        XCTAssertGreaterThan(sustained.double("time"), startTime + 9)
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(sustained.int("stalls") - startStalls, 1)
        XCTAssertEqual(sustained.int("engines"), 1)
        XCTAssertEqual(sustained.int("demux"), 1)
        XCTAssertEqual(sustained.int("renderers"), 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
        XCTAssertLessThan(sustained.double("memoryMB"), startMemory + 96)
    }

    func testNativeHLSPlaybackStartsAndCrossesSegmentBoundaries() throws {
        let app = launchPlayer(
            title: "native-hls-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                // Remux start: real HLS on any server.
                "-debug.regressionInitialDelivery", "remux",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("time") >= 0
        }
        try requireNegotiatedTranscode(initial)
        let startTime = initial.double("time")
        let startStalls = initial.int("stalls")
        let startMemory = initial.double("memoryMB")
        XCTAssertEqual(initial.int("cache"), 0)

        // The release path: no range cache between Jellyfin and the demuxer.
        Thread.sleep(forTimeInterval: 20)
        let sustained = state(in: app)
        XCTAssertGreaterThan(sustained.double("time"), startTime + 14)
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(sustained.int("stalls") - startStalls, 1)
        XCTAssertEqual(sustained.int("engines"), 1)
        XCTAssertEqual(sustained.int("demux"), 1)
        XCTAssertEqual(sustained.int("renderers"), 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
        XCTAssertLessThan(sustained.double("memoryMB"), startMemory + 96)
    }

    func testBufferedDirectH264PlaybackStartsAndSustains() throws {
        let app = launchPlayer(
            title: "native-direct-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.double("time") >= 0
        }
        let startTime = initial.double("time")
        let startStalls = initial.int("stalls")
        let startMemory = initial.double("memoryMB")
        XCTAssertEqual(initial.string("method"), "DirectPlay")
        XCTAssertEqual(initial.int("cache"), 1)

        Thread.sleep(forTimeInterval: 20)
        let sustained = state(in: app)
        XCTAssertGreaterThan(sustained.double("time"), startTime + 14)
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(sustained.int("stalls") - startStalls, 1)
        XCTAssertEqual(sustained.int("engines"), 1)
        XCTAssertEqual(sustained.int("demux"), 1)
        XCTAssertEqual(sustained.int("renderers"), 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
        XCTAssertGreaterThanOrEqual(sustained.double("buffered"), initial.double("buffered"))
        XCTAssertLessThan(sustained.double("memoryMB"), startMemory + 96)
    }

    func testBufferedDirectStreamPlaybackStartsAndSustainsWhenFixtureExists() throws {
        let app = launchPlayer(
            title: "native-direct-stream-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindDirectStream", "YES",
                "-playback.autoplayMode", "off",
            ]
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.string("method") == "DirectStream"
        }
        let startTime = initial.double("time")
        let startStalls = initial.int("stalls")
        let startMemory = initial.double("memoryMB")
        XCTAssertEqual(initial.int("cache"), 1)

        Thread.sleep(forTimeInterval: 20)
        let sustained = state(in: app)
        XCTAssertGreaterThan(sustained.double("time"), startTime + 14)
        XCTAssertEqual(sustained.int("buffering"), 0)
        XCTAssertLessThanOrEqual(sustained.int("stalls") - startStalls, 1)
        XCTAssertEqual(sustained.int("engines"), 1)
        XCTAssertEqual(sustained.int("demux"), 1)
        XCTAssertEqual(sustained.int("renderers"), 1)
        XCTAssertEqual(sustained.int("unclean"), 0)
        XCTAssertGreaterThanOrEqual(sustained.double("buffered"), initial.double("buffered"))
        XCTAssertLessThan(sustained.double("memoryMB"), startMemory + 96)
    }

    /// Builds open collapsed and expand on Select, and the list still
    /// scrolls, which on tvOS means focus has somewhere to go.
    func testChangelogBuildsExpandAndCollapse() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.settingsRegression", "YES",
        ]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        let homeTab = app.tabBars.buttons["Home"]
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let about = app.descendants(matching: .any)["settings.category.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        moveFocus(to: about, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        let changelogButton = app.descendants(matching: .any)["settings.about.changelog"]
        XCTAssertTrue(changelogButton.waitForExistence(timeout: 8))
        moveFocus(to: changelogButton, maxPresses: 8) { remote.press(.right) }
        moveFocus(to: changelogButton, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.changelog"].waitForExistence(timeout: 8),
            "the changelog sheet did not open"
        )

        for build in ["55", "54", "53"] {
            let row = app.descendants(matching: .any)["settings.changelog.\(build)"]
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "build \(build) should have a row of its own"
            )
        }

        // Matched on a fragment: XCUITest rejects queries over 128 characters.
        let olderNote = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "exhausted provider allowance"))
            .firstMatch
        XCTAssertFalse(olderNote.exists, "a collapsed build should not show its notes")

        let build53 = app.descendants(matching: .any)["settings.changelog.53"]
        // Every newer build adds a row above 53, so the budget is generous.
        moveFocus(to: build53, maxPresses: 80) { remote.press(.down) }
        remote.press(.select)
        XCTAssertTrue(
            olderNote.waitForExistence(timeout: 5),
            "opening a build should reveal its notes"
        )

        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(olderNote.exists, "pressing again should close it")
    }

    /// Picks a theme, then navigates browse and settings. Screenshots wait
    /// for the bloom to end so they show the settled palette.
    func testBabyPinkThemeFocusBrowseAndDeepChangelogNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.settingsRegression", "YES",
        ]
        app.launch()

        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        let homeTab = app.tabBars.buttons["Home"]
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let appearance = app.descendants(matching: .any)["settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 8))
        moveFocus(to: appearance, maxPresses: 10) { remote.press(.down) }
        remote.press(.select)
        let theme = app.descendants(matching: .any)["settings.appearance.theme"]
        // The Menu's value sits on a wrapper; the control inside owns focus.
        func themeHasFocus() -> Bool {
            theme.hasFocus || theme.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus)
        }
        func focusThemeControl() {
            for _ in 0..<3 where !themeHasFocus() {
                remote.press(.right)
                Thread.sleep(forTimeInterval: 0.2)
            }
            XCTAssertTrue(themeHasFocus(), "Could not focus Appearance's native theme control")
        }
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        focusThemeControl()
        XCTAssertEqual(theme.valueDescription, "Lagoon")
        remote.press(.select)
        selectNativeMenuOption("Baby Pink", in: app, menuIndex: 1)
        let pinkSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Baby Pink"), object: theme
        )
        XCTAssertEqual(XCTWaiter().wait(for: [pinkSelected], timeout: 5), .completed)
        // The bloom is hidden from accessibility; wait out its 1.7 s + 0.2 s fade.
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertTrue(themeHasFocus(), "Theme selection should preserve native control focus")
        capture("Baby Pink tvOS — settled Appearance and focused theme control")

        remote.press(.menu)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        moveFocus(to: settingsTab, maxPresses: 12) { remote.press(.up) }
        moveFocus(to: homeTab, maxPresses: 10) { remote.press(.left) }
        remote.press(.select)
        capture("Baby Pink tvOS — Home and system tab chrome")

        let genreButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.genre.")
        )
        var selectedGenre: XCUIElement?
        for _ in 0..<24 {
            selectedGenre = genreButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if selectedGenre != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let selectedGenre else {
            XCTFail("Could not focus a genre after scrolling Home in Baby Pink")
            return
        }
        capture("Baby Pink tvOS — deep Home genre shelf with native card focus")
        remote.press(.select)
        let genreLibrary = app.descendants(matching: .any)["genre.library"]
        XCTAssertTrue(genreLibrary.waitForExistence(timeout: 8))
        let populated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != '0 items'"), object: genreLibrary
        )
        XCTAssertEqual(XCTWaiter().wait(for: [populated], timeout: 20), .completed)
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.poster."))
        var selectedPoster: XCUIElement?
        for _ in 0..<8 {
            selectedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if selectedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let selectedPoster else {
            XCTFail("Could not focus a poster in the Baby Pink genre library")
            return
        }
        capture("Baby Pink tvOS — genre library and focused poster")
        let itemID = selectedPoster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        remote.press(.select)
        let detail = app.descendants(matching: .any)["detail.item.\(itemID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(detail.exists, "Detail should remain above the genre route")
        capture("Baby Pink tvOS — item detail")
        remote.press(.menu)
        XCTAssertTrue(genreLibrary.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(selectedGenre), "Back should restore the selected Home genre")

        moveFocus(to: homeTab, maxPresses: 30) { remote.press(.up) }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)
        let about = app.descendants(matching: .any)["settings.category.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        moveFocus(to: about, maxPresses: 14) { remote.press(.down) }
        remote.press(.select)
        let changelog = app.descendants(matching: .any)["settings.about.changelog"]
        XCTAssertTrue(changelog.waitForExistence(timeout: 5))
        remote.press(.right)
        if !waitForFocus(changelog, timeout: 1) {
            moveFocus(to: changelog, maxPresses: 8) { remote.press(.down) }
        }
        capture("Baby Pink tvOS — About with focused Changelog action")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.changelog"].waitForExistence(timeout: 8))
        let build100 = app.descendants(matching: .any)["settings.changelog.100"]
        XCTAssertTrue(build100.waitForExistence(timeout: 5))
        capture("Baby Pink tvOS — Build 100 categorized release notes")

        let build53 = app.descendants(matching: .any)["settings.changelog.53"]
        moveFocus(to: build53, maxPresses: 80) { remote.press(.down) }
        remote.press(.select)
        let olderNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "exhausted provider allowance")
        ).firstMatch
        XCTAssertTrue(olderNote.waitForExistence(timeout: 5))
        capture("Baby Pink tvOS — deeply scrolled and expanded historical release notes")
        remote.press(.select)
        moveFocus(to: build100, maxPresses: 80) { remote.press(.up) }
        XCTAssertTrue(build100.frame.intersects(app.frame), "Returning up should reveal Build 100 again")
        remote.press(.menu)
        XCTAssertTrue(changelog.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(about.waitForExistence(timeout: 5))

        moveFocus(to: appearance, maxPresses: 12) { remote.press(.up) }
        remote.press(.select)
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        focusThemeControl()
        remote.press(.select)
        selectNativeMenuOption("Lagoon", in: app, menuIndex: 0)
        let lagoonSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Lagoon"), object: theme
        )
        XCTAssertEqual(XCTWaiter().wait(for: [lagoonSelected], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 2.2)
        capture("Lagoon tvOS — default theme restored after navigation sweep")
    }

    func testTvOSSettingsHierarchyPickersAndHomeRowsNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.settingsRegression", "YES",
        ]
        app.launch()

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        let homeTab = app.tabBars.buttons["Home"]
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let playback = app.descendants(matching: .any)["settings.category.playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 8))
        remote.press(.select)
        let skipMode = app.descendants(matching: .any)["settings.playback.skipMode"]
        XCTAssertTrue(skipMode.waitForExistence(timeout: 5))
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["Skip Automatically"].waitForExistence(timeout: 5),
            "Playback controls column was unreachable"
        )
        remote.press(.menu)
        let detailBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: detailBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)

        let audio = app.descendants(matching: .any)["settings.category.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 8))
        moveFocus(to: audio, maxPresses: 5) { remote.press(.down) }
        remote.press(.select)

        let defaultAudio = app.descendants(matching: .any)["settings.audio.default"]
        XCTAssertTrue(defaultAudio.waitForExistence(timeout: 5))
        let detailDescription = app.descendants(matching: .any)["settings.detail.description"]
        XCTAssertTrue(detailDescription.waitForExistence(timeout: 3))
        XCTAssertLessThan(detailDescription.frame.midX, defaultAudio.frame.minX)
        // Move into the controls column first, or Select hits Back.
        remote.press(.right)
        remote.press(.select)
        // Native tvOS menu rows are cells with labelled descendants.
        let preferredLanguage = app.descendants(matching: .any)["Preferred Language"]
        XCTAssertTrue(preferredLanguage.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(preferredLanguage.frame.minX, defaultAudio.frame.midX)
        let menuScreenshot = XCTAttachment(screenshot: app.screenshot())
        menuScreenshot.name = "Settings split view with native audio menu"
        menuScreenshot.lifetime = .keepAlways
        add(menuScreenshot)
        remote.press(.menu)
        XCTAssertTrue(defaultAudio.waitForExistence(timeout: 3))

        let back = app.descendants(matching: .any)["settings.detail.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        moveFocus(to: back, maxPresses: 5) { remote.press(.left) }
        remote.press(.select)

        let subtitles = app.descendants(matching: .any)["settings.category.subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        moveFocus(to: subtitles, maxPresses: 4) { remote.press(.down) }
        remote.press(.select)
        let appearance = app.descendants(matching: .any)["settings.subtitles.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        remote.press(.right)
        moveFocus(to: appearance, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.subtitlePreview"].waitForExistence(timeout: 5))
        let systemStyle = app.descendants(matching: .any)["settings.subtitles.systemAppearance"]
        XCTAssertTrue(systemStyle.waitForExistence(timeout: 5))
        XCTAssertEqual(systemStyle.label, "Use System Caption Style")
        // A SwiftUI Toggle does not reliably report hasFocus, so prove Right
        // reached it by changing its value.
        let previousSystemStyle = systemStyle.valueDescription
        remote.press(.right)
        remote.press(.select)
        XCTAssertNotEqual(systemStyle.valueDescription, previousSystemStyle)
        let toggleScreenshot = XCTAttachment(screenshot: app.screenshot())
        toggleScreenshot.name = "Subtitle Appearance native toggle without duplicate state"
        toggleScreenshot.lifetime = .keepAlways
        add(toggleScreenshot)
        // Left must still reach Back from a control far below it.
        moveFocus(to: back, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        remote.press(.menu)

        let home = app.descendants(matching: .any)["settings.category.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        moveFocus(to: home, maxPresses: 4) { remote.press(.down) }
        remote.press(.select)
        let myList = app.descendants(matching: .any)["settings.home.row.MyList"]
        XCTAssertTrue(myList.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.home.row.lagoon.movieGenres"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.home.row.lagoon.showGenres"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "settings.home.row.MyList")
            ).count,
            1
        )
        let nativeContinueWatching = app.descendants(matching: .any)[
            "settings.home.row.lagoon.continueWatching"
        ]
        remote.press(.right)
        moveFocus(to: nativeContinueWatching, maxPresses: 3) { remote.press(.up) }
        XCTAssertTrue(nativeContinueWatching.hasFocus)
        let previousNativeVisibility = nativeContinueWatching.valueDescription
        remote.press(.select)
        XCTAssertNotEqual(nativeContinueWatching.valueDescription, previousNativeVisibility)
        let homeRowsScreenshot = XCTAttachment(screenshot: app.screenshot())
        homeRowsScreenshot.name = "Lagoon native and Home Screen Sections plugin rows"
        homeRowsScreenshot.lifetime = .keepAlways
        add(homeRowsScreenshot)
        // Row visibility persists per account, so restore it or later tests
        // (ServerSync steps a fixed number of rows) see a different Home.
        remote.press(.select)
        XCTAssertEqual(
            nativeContinueWatching.valueDescription,
            previousNativeVisibility,
            "The native row toggle was left flipped for the next test"
        )
        // Plugin rows come after every native row, so size the press budget
        // from the rows on screen rather than a fixed count.
        let homeRowCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "settings.home.")
        ).count
        moveFocus(to: myList, maxPresses: homeRowCount + 4) { remote.press(.down) }
        let previousVisibility = myList.valueDescription
        remote.press(.select)
        XCTAssertNotEqual(myList.valueDescription, previousVisibility)
        // Restore it, as above.
        remote.press(.select)
        XCTAssertEqual(
            myList.valueDescription,
            previousVisibility,
            "The plugin row toggle was left flipped for the next test"
        )
        remote.press(.menu)
        XCTAssertTrue(home.waitForExistence(timeout: 5))

        let seerr = app.descendants(matching: .any)["settings.category.seerr"]
        XCTAssertTrue(seerr.waitForExistence(timeout: 5))
        moveFocus(to: seerr, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let seerrServer = app.descendants(matching: .any)["settings.seerr.server"]
        XCTAssertTrue(seerrServer.waitForExistence(timeout: 5))
        remote.press(.right)
        XCTAssertTrue(seerrServer.hasFocus, "Seerr server controls column was unreachable")
        let seerrBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: seerrBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(seerr.waitForExistence(timeout: 5))

        let developer = app.descendants(matching: .any)["settings.category.developer"]
        moveFocus(to: developer, maxPresses: 5) { remote.press(.down) }
        remote.press(.select)
        let componentPicker = app.descendants(matching: .any)["settings.developer.component"]
        XCTAssertTrue(componentPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.developer.preview"]
                .waitForExistence(timeout: 5)
        )
        remote.press(.right)
        let developerScreenshot = XCTAttachment(screenshot: app.screenshot())
        developerScreenshot.name = "Debug-only player component gallery"
        developerScreenshot.lifetime = .keepAlways
        add(developerScreenshot)

        remote.press(.select)
        selectNativeMenuOption("Next Episode — Card", in: app, menuIndex: 4)
        let nextEpisodeSelection = NSPredicate(format: "value == %@", "Next Episode — Card")
        expectation(for: nextEpisodeSelection, evaluatedWith: componentPicker)
        waitForExpectations(timeout: 5)
        let nextEpisodeScreenshot = XCTAttachment(screenshot: app.screenshot())
        nextEpisodeScreenshot.name = "Debug-only next episode component preview"
        nextEpisodeScreenshot.lifetime = .keepAlways
        add(nextEpisodeScreenshot)

        // The panel preview uses the real controls, so focus must reach its
        // audio rows.
        remote.press(.select)
        selectNativeMenuOption("Player Panel", in: app, menuIndex: 10)
        let playerPanelSelection = NSPredicate(format: "value == %@", "Player Panel")
        expectation(for: playerPanelSelection, evaluatedWith: componentPicker)
        waitForExpectations(timeout: 5)
        let openPlayerPanel = app.buttons["settings.developer.playerPanel.open"]
        XCTAssertTrue(openPlayerPanel.waitForExistence(timeout: 5))
        moveFocus(to: openPlayerPanel, maxPresses: 3) { remote.press(.down) }
        remote.press(.select)
        let infoTab = app.buttons["player.tab.info"]
        let audioTab = app.buttons["player.tab.audio"]
        XCTAssertTrue(infoTab.waitForExistence(timeout: 5))
        XCTAssertTrue(infoTab.hasFocus)
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(audioTab.hasFocus)
        remote.press(.down)
        let firstAudioTrack = app.buttons["player.track.audio-1"]
        XCTAssertTrue(firstAudioTrack.waitForExistence(timeout: 3))
        XCTAssertTrue(firstAudioTrack.hasFocus)
        let panelScreenshot = XCTAttachment(screenshot: app.screenshot())
        panelScreenshot.name = "Debug-only interactive production player panel"
        panelScreenshot.lifetime = .keepAlways
        add(panelScreenshot)

        remote.press(.menu)
        XCTAssertTrue(componentPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(componentPicker.valueDescription, "Player Panel")
        remote.press(.menu)
        XCTAssertTrue(developer.waitForExistence(timeout: 5))

        let diagnostics = app.descendants(matching: .any)["settings.category.diagnostics"]
        moveFocus(to: diagnostics, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let hud = app.descendants(matching: .any)["settings.diagnostics.hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertEqual(hud.label, "Show Playback Details")
        let previousHUDValue = hud.valueDescription
        remote.press(.right)
        remote.press(.select)
        XCTAssertNotEqual(hud.valueDescription, previousHUDValue)
        let diagnosticsScreenshot = XCTAttachment(screenshot: app.screenshot())
        diagnosticsScreenshot.name = "Diagnostics native toggle without duplicate state"
        diagnosticsScreenshot.lifetime = .keepAlways
        add(diagnosticsScreenshot)
        let diagnosticsBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: diagnosticsBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))

        let account = app.descendants(matching: .any)["settings.category.account"]
        moveFocus(to: account, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let addAccount = app.buttons["settings.account.add"]
        XCTAssertTrue(addAccount.waitForExistence(timeout: 5))
        // Right from Back must cross the non-focusable Connection rows.
        remote.press(.right)
        XCTAssertTrue(addAccount.hasFocus, "Account actions column was unreachable")
        let accountScreenshot = XCTAttachment(screenshot: app.screenshot())
        accountScreenshot.name = "Account actions reachable past connection information"
        accountScreenshot.lifetime = .keepAlways
        add(accountScreenshot)
        let accountBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: accountBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
    }

    /// `testPlayerPanelPreviewPerformance` over live playback, to show what
    /// per-tick invalidation costs the panel's focus animations.
    ///
    /// No assertions inside the measured block: focus asserts over live
    /// playback flake. The result is checked once afterwards.
    ///
    /// The tvOS simulator reports no hitch figures; read the CPU counters.
    func testLivePlayerPanelSweepPerformance() throws {
        let app = launchPlayer(
            title: "live-panel-sweep-regression",
            simulatorTranscode: false,
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.regressionRequireAudio", "YES",
                // A transcode may still be encoding when the position check runs.
                "-debug.regressionRequireDirectPlay", "YES",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 60) { $0.int("ready") == 1 && $0.int("buffering") == 0 }
        // Otherwise this measures a still frame.
        let startingTime = state(in: app).double("time")
        waitForState(in: app, timeout: 15) { $0.double("time") > startingTime + 1 }

        remote.press(.down)
        waitForState(in: app, timeout: 8) { $0.int("panel") == 1 }
        waitForPanelReveal()
        let infoTab = app.buttons["player.tab.info"]
        let subtitleTab = app.buttons["player.tab.subtitles"]
        XCTAssertTrue(infoTab.waitForExistence(timeout: 8))
        XCTAssertTrue(subtitleTab.waitForExistence(timeout: 8))
        // The surface keeps focus until a tab accepts it (see CustomPlayerView).
        // One unmeasured round trip makes every iteration start the same way.
        moveRight(toTab: "subtitles", in: app)
        moveLeft(toTab: "info", in: app)

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [
                XCTClockMetric(),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTHitchMetric(application: app),
            ],
            options: options
        ) {
            for _ in 0..<3 { remote.press(.right) }
            _ = subtitleTab.hasFocus
            // Into the track rows and back, where the card animates focus.
            remote.press(.down)
            remote.press(.up)
            _ = subtitleTab.hasFocus
            for _ in 0..<3 { remote.press(.left) }
            _ = infoTab.hasFocus
        }

        let resting = waitForState(in: app, timeout: 8) { $0.string("tab") == "info" }
        XCTAssertEqual(resting.int("panel"), 1, "The sweep left the panel closed")
        let sweepScreenshot = XCTAttachment(screenshot: app.screenshot())
        sweepScreenshot.name = "Live player panel after the sweep"
        sweepScreenshot.lifetime = .keepAlways
        add(sweepScreenshot)

        // A stalled player would make the numbers above meaningless.
        let afterSweep = state(in: app).double("time")
        waitForState(in: app, timeout: 15) { $0.double("time") > afterSweep + 1 }

        remote.press(.menu)
        waitForState(in: app, timeout: 8) { $0.int("panel") == 0 }
    }

    func testPlayerPanelPreviewPerformance() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.settingsRegression", "YES",
        ]
        app.launch()
        openPlayerPanelPreview(in: app)

        let infoTab = app.buttons["player.tab.info"]
        let subtitleTab = app.buttons["player.tab.subtitles"]
        XCTAssertTrue(infoTab.waitForExistence(timeout: 5))
        XCTAssertTrue(subtitleTab.waitForExistence(timeout: 5))
        XCTAssertTrue(infoTab.hasFocus)
        XCTAssertFalse(
            app.buttons["player.pictureInPicture"].exists,
            "Picture in Picture must not appear in the tvOS player panel"
        )

        // Track names get more room than the delay controls, without overlap.
        remote.press(.right)
        remote.press(.right)
        let firstAudioTrack = app.buttons["player.track.audio-1"]
        let audioDelayDecrease = app.buttons["player.audioDelay.decrease"]
        let audioDelayIncrease = app.buttons["player.audioDelay.increase"]
        XCTAssertTrue(firstAudioTrack.waitForExistence(timeout: 3))
        XCTAssertTrue(audioDelayDecrease.waitForExistence(timeout: 3))
        XCTAssertTrue(audioDelayIncrease.waitForExistence(timeout: 3))
        XCTAssertGreaterThan(firstAudioTrack.frame.width, app.frame.width * 0.33)
        XCTAssertLessThan(firstAudioTrack.frame.width, app.frame.width * 0.45)
        XCTAssertLessThan(firstAudioTrack.frame.maxX, audioDelayDecrease.frame.minX)
        XCTAssertLessThan(audioDelayDecrease.frame.maxX, audioDelayIncrease.frame.minX)
        let audioPanelScreenshot = XCTAttachment(screenshot: app.screenshot())
        audioPanelScreenshot.name = "Compact player Audio panel"
        audioPanelScreenshot.lifetime = .keepAlways
        add(audioPanelScreenshot)
        remote.press(.left)
        remote.press(.left)
        XCTAssertTrue(infoTab.hasFocus)

        let performanceProbe = app.descendants(matching: .any)["player.panel.performance"]
        XCTAssertTrue(performanceProbe.waitForExistence(timeout: 5))
        let initialMemory = RegressionState(
            performanceProbe.value as? String ?? ""
        ).double("memoryMB")
        XCTAssertGreaterThan(initialMemory, 0, "Panel memory probe did not return a footprint")

        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(
            metrics: [
                XCTClockMetric(),
                XCTCPUMetric(application: app),
                XCTMemoryMetric(application: app),
                XCTHitchMetric(application: app),
            ],
            options: options
        ) {
            let startedAt = ProcessInfo.processInfo.systemUptime
            for _ in 0..<3 { remote.press(.right) }
            XCTAssertTrue(subtitleTab.hasFocus)
            for _ in 0..<3 { remote.press(.left) }
            XCTAssertTrue(infoTab.hasFocus)
            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime - startedAt,
                1.75,
                "A six-tab panel sweep exceeded the tvOS responsiveness ceiling"
            )
        }

        // Lazy track rows must still navigate: walk the 30-track fixture.
        for _ in 0..<3 { remote.press(.right) }
        // The gallery opens on the search results; Done brings back the
        // track chooser, or the walk below counts result rows.
        let doneButton = app.buttons["player.subtitleSearch.close"]
        if doneButton.waitForExistence(timeout: 3) {
            // Down may land on the language menu beside Done; walk left, then up.
            remote.press(.down)
            for direction in [XCUIRemote.Button.left, .up] {
                for _ in 0..<3 where !doneButton.hasFocus {
                    remote.press(direction)
                    Thread.sleep(forTimeInterval: 0.2)
                }
            }
            XCTAssertTrue(waitForFocus(doneButton), "Could not reach Done in the results browser")
            remote.press(.select)
        }
        // Reach Off by focus so only the 30-row walk is counted.
        let subtitleOff = app.buttons["player.track.subtitle-off"]
        XCTAssertTrue(
            subtitleOff.waitForExistence(timeout: 5),
            "Leaving the results browser must reveal the track chooser"
        )
        moveFocus(to: subtitleOff, maxPresses: 6) { remote.press(.down) }
        for _ in 0..<30 { remote.press(.down) }
        let finalTrack = app.buttons["player.track.subtitle-40"]
        XCTAssertTrue(finalTrack.hasFocus)
        XCTAssertGreaterThan(finalTrack.frame.minY, subtitleTab.frame.maxY)
        XCTAssertLessThan(finalTrack.frame.maxY, app.frame.maxY)
        let finalMemory = RegressionState(
            performanceProbe.value as? String ?? ""
        ).double("memoryMB")
        XCTAssertGreaterThan(finalMemory, 0, "Panel memory probe stopped reporting a footprint")
        XCTAssertLessThanOrEqual(
            finalMemory,
            initialMemory + 12,
            "Repeated panel sweeps and the 30-track stress list retained too much memory"
        )
    }

    func testControlledFrameLossPlaybackPerformance() throws {
        // Three runs of the same item and position are the minimum useful
        // comparison. The app replays the resolved item, so the scene is fixed.
        let app = launchPlayer(
            title: "frame-loss-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.frameLossBench", "YES",
                "-debug.lifecycleReplayBenchmark", "YES",
                "-debug.lifecycleReplayDelaySeconds", "2",
                "-debug.lifecycleReplayCount", "2",
            ]
        )
        try requireRegressionFixture(in: app)

        var results: [FrameLossRegressionResult] = []
        for run in 1...3 {
            let ready = waitForState(in: app, timeout: 60) {
                $0.int("ready") == 1 && $0.int("buffering") == 0
            }
            let startingStalls = ready.int("stalls")
            let startingIdleRequests = ready.int("idleRequests")

            // Leave the simulator untouched through the 10 s warmup and 60 s
            // window: polling and screenshots perturb presentation.
            Thread.sleep(forTimeInterval: 74)
            let result = try waitForFrameLossResult(in: app, timeout: 25)
            results.append(result)
            XCTAssertLessThan(
                state(in: app).int("idleRequests") - startingIdleRequests, 2_000,
                "Run \(run): renderer request blocks kept firing with nothing to give"
            )

            XCTAssertGreaterThan(result.frames, 1_000, "Run \(run) did not cover a full 60 s scene")
            XCTAssertEqual(result.corrupted, 0, "Run \(run) presented corrupted frames")
            XCTAssertLessThanOrEqual(result.stalls, 1, "Run \(run) repeatedly stalled")
            XCTAssertEqual(result.audioGaps, 0, "Run \(run) enqueued discontinuous audio")
            XCTAssertLessThanOrEqual(
                result.lossPercent,
                1,
                "Run \(run) exceeded the simulator frame-loss regression ceiling"
            )
            XCTAssertLessThanOrEqual(
                state(in: app).int("stalls") - startingStalls,
                1,
                "Run \(run) accumulated stalls outside the measured window"
            )

            remote.press(.menu)
            let cleanup = waitForLifecycle(in: app, timeout: 10) {
                $0.int("engines") == 0
                    && $0.int("controllers") == 0
                    && $0.int("demux") == 0
                    && $0.int("renderers") == 0
            }
            XCTAssertEqual(cleanup.int("unclean"), 0)
        }

        let spread = (results.map(\.lossPercent).max() ?? 0)
            - (results.map(\.lossPercent).min() ?? 0)
        XCTAssertLessThanOrEqual(
            spread,
            0.5,
            "Same-scene frame loss varied too much across three clean playback sessions"
        )
    }

    func testVC1DirectPlayMaintainsContinuousAudioAndVideo() throws {
        let series = ProcessInfo.processInfo.environment["LAGOON_VC1_SERIES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Rick and Morty"
        let vc1Arguments = [
            "-debug.regressionFindVC1InSeries", "YES",
            "-debug.frameLossBench", "YES",
            "-debug.lifecycleReplayBenchmark", "YES",
            "-debug.lifecycleReplayDelaySeconds", "60",
            "-debug.lifecycleReplayCount", "1",
            "-playback.autoplayMode", "off",
        ]
        let app = launchPlayer(
            title: "vc1-continuity-regression",
            series: series,
            simulatorTranscode: false,
            extraArguments: vc1Arguments
        )
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1
                && $0.int("buffering") == 0
                && $0.string("method") == "DirectPlay"
                && $0.int("cache") == 1
                && $0.string("audioPath") == "LPCM"
        }
        let initialStalls = initial.int("stalls")
        let initialMemory = initial.double("memoryMB")

        // Sample memory after warmup: the decoder's one-time pixel buffer
        // pool would otherwise look like a leak.
        Thread.sleep(forTimeInterval: 14)
        let warmed = state(in: app)
        // The decoded-surface working set grows lazily; a later baseline makes
        // the leak gate measure steady-state slope.
        Thread.sleep(forTimeInterval: 30)
        let settled = state(in: app)
        let steadySeconds = ProcessInfo.processInfo.environment["LAGOON_VC1_STEADY_SECONDS"]
            .flatMap(Double.init) ?? 60
        Thread.sleep(forTimeInterval: max(steadySeconds, 60))
        let result = try waitForFrameLossResult(in: app, timeout: 25)
        let final = state(in: app)

        let activeDiagnostics = XCTAttachment(string: [
            String(format: "initialMemoryMB=%.1f", initialMemory),
            String(format: "warmedMemoryMB=%.1f", warmed.double("memoryMB")),
            String(format: "settledMemoryMB=%.1f", settled.double("memoryMB")),
            String(format: "finalMemoryMB=%.1f", final.double("memoryMB")),
            "frames=\(result.frames)",
            "dropped=\(result.dropped)",
            String(format: "lossPercent=%.3f", result.lossPercent),
            "corrupted=\(result.corrupted)",
            "stalls=\(result.stalls)",
            "audioGaps=\(result.audioGaps)",
        ].joined(separator: " "))
        activeDiagnostics.name = "VC-1 active playback metrics"
        activeDiagnostics.lifetime = .keepAlways
        add(activeDiagnostics)

        remote.press(.menu)
        let cleanup = waitForLifecycle(in: app, timeout: 10) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }

        let diagnostics = XCTAttachment(string: [
            String(format: "initialMemoryMB=%.1f", initialMemory),
            String(format: "warmedMemoryMB=%.1f", warmed.double("memoryMB")),
            String(format: "settledMemoryMB=%.1f", settled.double("memoryMB")),
            String(format: "finalMemoryMB=%.1f", final.double("memoryMB")),
            String(format: "cleanupMemoryMB=%.1f", cleanup.double("memoryMB")),
            "frames=\(result.frames)",
            "dropped=\(result.dropped)",
            String(format: "lossPercent=%.3f", result.lossPercent),
            "corrupted=\(result.corrupted)",
            "stalls=\(result.stalls)",
            "audioGaps=\(result.audioGaps)",
        ].joined(separator: " "))
        diagnostics.name = "VC-1 continuity metrics"
        diagnostics.lifetime = .keepAlways
        add(diagnostics)

        XCTAssertGreaterThan(result.frames, 1_000)
        XCTAssertEqual(result.corrupted, 0)
        XCTAssertEqual(result.audioGaps, 0, "VC-1 playback enqueued discontinuous audio")
        XCTAssertLessThanOrEqual(result.stalls, 1)
        XCTAssertLessThanOrEqual(result.lossPercent, 1)
        XCTAssertLessThanOrEqual(final.int("stalls") - initialStalls, 1)
        XCTAssertEqual(final.int("buffering"), 0)
        XCTAssertEqual(final.int("engines"), 1)
        XCTAssertEqual(final.int("demux"), 1)
        XCTAssertEqual(final.int("renderers"), 1)
        XCTAssertEqual(final.int("unclean"), 0)
        XCTAssertLessThanOrEqual(
            final.double("memoryMB"),
            settled.double("memoryMB") + 64,
            "VC-1 playback allocator high-water exceeded its bounded reclamation allowance"
        )
        XCTAssertLessThan(
            final.double("memoryMB"),
            initialMemory + 160,
            "VC-1 active playback exceeded its conservative decoded-frame allowance"
        )
        XCTAssertEqual(cleanup.int("unclean"), 0)
        XCTAssertLessThanOrEqual(
            cleanup.double("memoryMB"),
            initialMemory + 48,
            "VC-1 decoder or renderer memory remained live after dismissal"
        )
    }

    /// The software-decoded path survives pause, seeks both ways and
    /// subtitles. Device and Release only (`-configuration Release`): the
    /// simulator never starts the clock on this E-AC3 track, and Debug cannot
    /// hold 4K AV1 through a seek. The fixture comes from the environment.
    func testSoftwareDecodedPlaybackSurvivesPauseSeeksAndSubtitles() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("the software-decoded fixture's audio never starts the clock in the simulator")
        #else
        let environment = ProcessInfo.processInfo.environment
        let title = environment["LAGOON_SOFTWARE_DECODE_TITLE"] ?? "Rise"
        let series = environment["LAGOON_SOFTWARE_DECODE_SERIES"] ?? "The Dinosaurs"
        let app = launchPlayer(title: title, series: series, simulatorTranscode: false)
        try requireRegressionFixture(in: app)
        let initial = waitForState(in: app, timeout: 90) {
            $0.int("ready") == 1 && $0.int("buffering") == 0 && $0.double("time") > 0
        }
        XCTAssertTrue(
            initial.string("videoPath").hasPrefix("gpu-"),
            "expected the GPU output stage, got \(initial.string("videoPath"))"
        )
        // Let the automatic intro skip land, or the pause check measures it.
        let introEnd = initial.double("skippableEnd")
        if introEnd > 0 {
            waitForState(in: app, timeout: 60) { $0.double("time") > introEnd + 1 }
        }
        let settled = state(in: app)
        let initialStalls = settled.int("stalls")
        let initialIdleRequests = settled.int("idleRequests")
        let started = Date()

        let startingTime = settled.double("time")
        waitForState(in: app, timeout: 10) { $0.double("time") > startingTime + 3 }

        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
        let pausedTime = state(in: app).double("time")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(abs(state(in: app).double("time") - pausedTime), 0.8)
        remote.press(.playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }

        let beforeForward = state(in: app).double("time")
        remote.press(.right)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        for _ in 0..<3 {
            Thread.sleep(forTimeInterval: 0.35)
            remote.press(.right)
        }
        remote.press(.select)
        waitForState(in: app, timeout: 60) {
            $0.int("scrubbing") == 0 && $0.int("buffering") == 0 && $0.double("time") > beforeForward + 5
        }
        // The new position has to decode and present, not merely be reached.
        let afterForward = state(in: app).double("time")
        waitForState(in: app, timeout: 20) { $0.double("time") > afterForward + 4 }

        let beforeBackward = state(in: app).double("time")
        remote.press(.left)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        remote.press(.select)
        // A 4K AV1 backward seek decodes from the previous keyframe, so judge
        // where it landed, not how fast.
        waitForState(in: app, timeout: 60) {
            $0.int("scrubbing") == 0
                && $0.int("buffering") == 0
                && $0.double("lastScrub") > 0
                && $0.double("lastScrub") < beforeBackward
                && $0.double("time") >= $0.double("lastScrub")
                && $0.double("time") < $0.double("lastScrub") + 30
        }

        if state(in: app).int("subtitleCount") > 0 {
            selectFirstSubtitle(in: app)
        }

        let resumed = state(in: app).double("time")
        waitForState(in: app, timeout: 25) { $0.double("time") > resumed + 8 }
        let final = state(in: app)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(final.int("buffering"), 0)
        XCTAssertLessThanOrEqual(final.int("stalls") - initialStalls, 2)
        XCTAssertEqual(final.int("engines"), 1)
        XCTAssertEqual(final.int("unclean"), 0)
        XCTAssertLessThan(
            Double(final.int("idleRequests") - initialIdleRequests) / elapsed, 50,
            "renderer request blocks kept firing with nothing to give"
        )

        remote.press(.menu)
        let playerProbe = app.descendants(matching: .any)["player.regression.state"]
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: playerProbe
        )
        XCTAssertEqual(XCTWaiter().wait(for: [dismissed], timeout: 20), .completed, "the player did not dismiss")
        // The lifecycle probe exists only in Debug, and this test runs in Release.
        if app.descendants(matching: .any)["app.lifecycle.state"].exists {
            let cleanup = waitForLifecycle(in: app, timeout: 15) {
                $0.int("engines") == 0
                    && $0.int("controllers") == 0
                    && $0.int("demux") == 0
                    && $0.int("renderers") == 0
            }
            XCTAssertEqual(cleanup.int("unclean"), 0)
        }
        #endif
    }

    func testPlaybackDismissSettingsReplayLifecycleAndStallBenchmark() {
        let requestedVC1Series = ProcessInfo.processInfo.environment["LAGOON_LIFECYCLE_VC1_SERIES"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedReplayCount = Int(
            ProcessInfo.processInfo.environment["LAGOON_LIFECYCLE_REPLAYS"] ?? ""
        ) ?? 3
        // Three cycles show a small per-replay leak; cap it at ten.
        let replayCount = min(max(requestedReplayCount, 1), 10)
        var resolverArguments: [String]
        if let requestedVC1Series, !requestedVC1Series.isEmpty {
            resolverArguments = ["-debug.regressionFindVC1InSeries", "YES"]
        } else {
            resolverArguments = ["-debug.regressionFindPlayable", "YES"]
        }
        let app = launchPlayer(
            title: "lifecycle-regression",
            series: requestedVC1Series,
            extraArguments: [
                "-debug.lifecycleReplayBenchmark", "YES",
                "-debug.lifecycleReplayDelaySeconds", "12",
                "-debug.lifecycleReplayCount", String(replayCount),
            ] + resolverArguments
        )
        let firstReady = waitForState(in: app, timeout: 60) {
            $0.int("ready") == 1 && $0.int("buffering") == 0
        }
        let firstStart = firstReady.double("time")
        let firstMemory = firstReady.double("memoryMB")
        waitForState(in: app, timeout: 12) { $0.double("time") > firstStart + 3 }

        remote.press(.menu)
        let firstCleanup = waitForLifecycle(in: app, timeout: 10) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(firstCleanup.int("unclean"), 0)

        // Settings must stay responsive while the first player's resources retire.
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        let homeTab = app.tabBars.buttons["Home"]
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.1)
        }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.category.audio"].waitForExistence(timeout: 5)
        )

        for replayIndex in 1...replayCount {
            let replayReady = waitForState(in: app, timeout: 60) {
                $0.int("ready") == 1 && $0.int("buffering") == 0
            }
            let replayStart = replayReady.double("time")
            let replayStalls = replayReady.int("stalls")
            XCTAssertLessThanOrEqual(
                replayReady.double("memoryMB"),
                firstMemory + 96,
                "Replay \(replayIndex) retained more than one conservative media-buffer allowance"
            )

            if replayIndex == 1 {
                let options = XCTMeasureOptions()
                options.iterationCount = 1
                measure(
                    metrics: [
                        XCTClockMetric(),
                        XCTCPUMetric(application: app),
                        XCTMemoryMetric(application: app),
                        XCTHitchMetric(application: app),
                    ],
                    options: options
                ) {
                    Thread.sleep(forTimeInterval: 15)
                }
            } else {
                Thread.sleep(forTimeInterval: 5)
            }

            let replayResult = state(in: app)
            let requiredAdvance = replayIndex == 1 ? 10.0 : 3.0
            XCTAssertGreaterThan(
                replayResult.double("time"),
                replayStart + requiredAdvance,
                "Replay \(replayIndex) did not sustain real-time playback"
            )
            XCTAssertEqual(replayResult.int("buffering"), 0)
            XCTAssertLessThanOrEqual(
                replayResult.int("stalls") - replayStalls,
                1,
                "Replay \(replayIndex) repeatedly stalled after a clean teardown"
            )

            remote.press(.menu)
            let cleanup = waitForLifecycle(in: app, timeout: 10) {
                $0.int("engines") == 0
                    && $0.int("controllers") == 0
                    && $0.int("demux") == 0
                    && $0.int("renderers") == 0
            }
            XCTAssertEqual(cleanup.int("unclean"), 0)
            XCTAssertLessThanOrEqual(
                cleanup.double("memoryMB"),
                firstCleanup.double("memoryMB") + 48,
                "Dismissed playback footprint grew by replay \(replayIndex)"
            )
        }
    }

    func testDismissDuringSuspendedStartupDoesNotResurrectPlaybackWork() throws {
        let app = launchPlayer(
            title: "startup-dismiss-regression",
            extraArguments: [
                "-debug.regressionFindPlayable", "YES",
                "-debug.lifecycleReplayBenchmark", "YES",
                // Mounts the lifecycle probe; the replay comes too late to overlap.
                "-debug.lifecycleReplayDelaySeconds", "60",
                "-debug.regressionPlaybackStartDelaySeconds", "5",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 60) { $0.int("ready") == 1 }

        remote.press(.menu)
        let cleanup = waitForLifecycle(in: app, timeout: 10) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(cleanup.int("unclean"), 0)

        // After the injected delay, a cancelled startup must stay cancelled.
        Thread.sleep(forTimeInterval: 6)
        let settled = waitForLifecycle(in: app, timeout: 2) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(settled.int("unclean"), 0)
        XCTAssertFalse(app.descendants(matching: .any)["player.regression.state"].exists)
    }

    func testHomeHeroLibraryAndNestedDetailBackStacks() throws {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))

        let hero = try requireHomeHero(in: app)
        moveFocus(to: hero, maxPresses: 8) { remote.press(.down) }
        let heroItemID = hero.identifier.replacingOccurrences(of: "home.hero.", with: "")
        remote.press(.select)

        let heroDetail = app.descendants(matching: .any)["detail.item.\(heroItemID)"]
        XCTAssertTrue(heroDetail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(heroDetail.exists, "Home hero detail did not remain the top route")
        remote.press(.menu)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.hasFocus, "Back did not restore focus to the selected Home hero")

        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        var libraryTabs: [XCUIElement] = []
        for _ in 0..<40 {
            libraryTabs = app.tabBars.buttons.allElementsBoundByIndex.filter {
                !["Home", "Discover", "Search", "Settings"].contains($0.label)
            }
            if !libraryTabs.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let libraryTab = libraryTabs.first(where: {
            $0.label.localizedCaseInsensitiveContains("movie")
        }) ?? libraryTabs.first else {
            XCTFail("No content library tab was loaded")
            return
        }
        moveFocus(to: libraryTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let library = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "library.view")
        ).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "value != '0 items'"), evaluatedWith: library)
        waitForExpectations(timeout: 20)

        // Library may restore All or Shows from an earlier visit; pick Movies.
        let picker = app.descendants(matching: .any)["library.kind"]
        func pickerOwnsFocus() -> Bool {
            picker.hasFocus || picker.descendants(matching: .any)
                .allElementsBoundByIndex.contains(where: \.hasFocus)
        }
        for _ in 0..<10 where !pickerOwnsFocus() {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(pickerOwnsFocus())
        remote.press(.select)
        let all = app.cells.containing(NSPredicate(format: "label == %@", "All")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        moveFocus(to: all, maxPresses: 4) { remote.press(.up) }
        let movies = app.cells.containing(NSPredicate(format: "label == %@", "Movies")).firstMatch
        moveFocus(to: movies, maxPresses: 4) { remote.press(.down) }
        XCTAssertTrue(movies.hasFocus)
        remote.press(.select)
        XCTAssertTrue(movies.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Movies")

        let posters = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        XCTAssertTrue(posters.firstMatch.waitForExistence(timeout: 12))
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("No library poster received focus")
            return
        }
        let libraryItemID = focusedPoster.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        remote.press(.select)

        let firstDetail = app.descendants(matching: .any)["detail.item.\(libraryItemID)"]
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 8))
        let relatedCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        XCTAssertTrue(relatedCards.firstMatch.waitForExistence(timeout: 12))
        var focusedRelated: XCUIElement?
        for _ in 0..<16 {
            focusedRelated = relatedCards.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedRelated != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedRelated else {
            XCTFail("More Like This could not receive focus")
            return
        }
        let relatedID = focusedRelated.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        remote.press(.select)

        let secondDetail = app.descendants(matching: .any)["detail.item.\(relatedID)"]
        XCTAssertTrue(secondDetail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(secondDetail.exists, "Nested detail did not remain the top route")
        remote.press(.menu)
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(secondDetail.exists)
        remote.press(.menu)
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertFalse(firstDetail.exists)
        XCTAssertTrue(focusedPoster.hasFocus, "Library focus was not restored after two details")
    }

    /// On tvOS `.searchable` draws a full keyboard, which pushes Discover's
    /// content below the fold, so search lives in its own tab.
    func testDiscoverBrowsesWithoutASearchFieldAndSearchHasItsOwnTab() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let discoverTab = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Search"].exists, "Search lost its tab")
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: discoverTab, maxPresses: 4) { remote.press(.right) }
        remote.press(.select)

        let discover = app.descendants(matching: .any)["seerr.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.searchFields.firstMatch.exists,
            "Discover is browsing behind a keyboard again"
        )
    }

    /// Back from a result returns to the same list, focused on the opened
    /// poster, without rebuilding the search.
    func testSearchDetailBackStackPreservesResultsAndFocus() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: searchTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let search = app.descendants(matching: .any)["search.view"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        expectation(
            for: NSPredicate(format: "NOT (value BEGINSWITH '0 library')"),
            evaluatedWith: search
        )
        waitForExpectations(timeout: 20)
        let resultCount = search.valueDescription

        let posters = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("No Search result received focus")
            return
        }
        let itemID = focusedPoster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        remote.press(.select)

        let detail = app.descendants(matching: .any)["detail.item.\(itemID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(detail.exists, "Search detail did not remain the top route")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "Search field overlaid the detail page")
        remote.press(.menu)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.valueDescription, resultCount, "Search results were rebuilt on Back")
        XCTAssertTrue(focusedPoster.hasFocus, "Search focus was not restored to the selected result")
    }

    /// An empty search offers no See All: the page behind it would be empty,
    /// with nothing to hold focus, so Menu would quit the app.
    func testEmptySearchDropsSeeAllAndStillCarriesFocusBelowTheLibrarySection() {
        let app = launchSeededSearchApp(query: "zzqxjvw")
        let homeTab = app.tabBars.buttons["Home"]
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: searchTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        // Drawn only once the seeded query has come back empty.
        let empty = app.staticTexts["No matching movies or shows in your library."]
        XCTAssertTrue(empty.waitForExistence(timeout: 25), "The seeded query never reached its empty state")
        let seeAll = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'see all'"))
        XCTAssertEqual(seeAll.count, 0, "An empty search still offers a See All into an empty page")

        // Down must carry past the unfocusable status block to the Seerr
        // setup link (Seerr is unconfigured in this lane).
        let setUpSeerr = app.buttons["search.seerr.setup"]
        XCTAssertTrue(setUpSeerr.waitForExistence(timeout: 10))
        moveFocus(to: setUpSeerr, maxPresses: 12) { remote.press(.down) }
    }

    func testDiscoverSetupNavigationAndBackFocus() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let discoverTab = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: discoverTab, maxPresses: 4) { remote.press(.right) }
        remote.press(.select)

        let setup = app.buttons["seerr.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 8))
        moveFocus(to: setup, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        let server = app.descendants(matching: .any)["settings.seerr.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        remote.press(.right)
        XCTAssertTrue(server.hasFocus, "Discover's Seerr setup controls were unreachable")

        let back = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: back, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(setup.hasFocus, "Back did not restore focus to Set Up Seerr")
    }

    func testNativeGenreShelfDetailNavigationAndBackStack() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        let genreButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.genre.")
        )

        var focusedGenre: XCUIElement?
        for _ in 0..<20 {
            focusedGenre = genreButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedGenre != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.25)
        }

        guard var selectedGenreButton = focusedGenre else {
            XCTFail("Could not focus a card in the native Genres shelf")
            return
        }
        // Prefer Action when the demo has it; any genre takes the same path.
        let actionGenre = genreButtons.matching(
            NSPredicate(format: "label ==[c] %@", "Action genre")
        ).firstMatch
        if actionGenre.exists {
            moveFocus(to: actionGenre, maxPresses: 24) {
                remote.press(.right)
            }
            selectedGenreButton = actionGenre
        }

        let selectedGenre = selectedGenreButton.label
        let shelfScreenshot = XCTAttachment(screenshot: app.screenshot())
        shelfScreenshot.name = "Native Genres shelf — \(selectedGenre) focused"
        shelfScreenshot.lifetime = .keepAlways
        add(shelfScreenshot)
        remote.press(.select)

        let library = app.descendants(matching: .any)["genre.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), "Did not open \(selectedGenre)")
        let title = app.descendants(matching: .any)["genre.library.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let populated = NSPredicate(format: "value != '0 items'")
        expectation(for: populated, evaluatedWith: library)
        waitForExpectations(timeout: 20)

        let posterButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posterButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("Could not focus the first poster in \(selectedGenre)")
            return
        }
        let selectedPosterID = focusedPoster.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        let selectedPosterName = focusedPoster.label
        remote.press(.select)

        let detail = app.descendants(matching: .any)["detail.item.\(selectedPosterID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8), "Did not open \(selectedPosterName)")
        // Detail could flash and pop back to the genre; wait to prove it stays.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(detail.exists, "Detail popped behind the genre library")

        remote.press(.menu)
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertFalse(detail.exists, "Back left the item detail above the genre library")

        remote.press(.menu)
        XCTAssertTrue(
            app.descendants(matching: .any)["home.genres.movies"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["home.genres.shows"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(library.exists, "Second Back did not return from genre to Home")

        // Back restores focus to the exact genre card.
        XCTAssertTrue(selectedGenreButton.hasFocus)
        remote.press(.select)
        XCTAssertTrue(library.waitForExistence(timeout: 8))

        // The demo catalogue changes; only assert scrolling when there are enough rows.
        if posterButtons.count > 8 {
            for _ in 0..<6 {
                remote.press(.down)
                Thread.sleep(forTimeInterval: 0.15)
            }
            XCTAssertFalse(
                title.frame.intersects(app.frame),
                "The genre heading should scroll away instead of covering the poster grid"
            )
        }
    }

    /// Presses, then waits on the app's tab state before pressing again, so a
    /// swallowed press is retried and a landed one never overshoots.
    private func pressUntil(
        tab target: String,
        in app: XCUIApplication,
        press direction: XCUIRemote.Button,
        attempts: Int = 4
    ) {
        for _ in 0..<attempts {
            if state(in: app).string("tab") == target { return }
            remote.press(direction)
            let deadline = Date().addingTimeInterval(1.5)
            repeat {
                if state(in: app).string("tab") == target { return }
                Thread.sleep(forTimeInterval: 0.1)
            } while Date() < deadline
        }
        waitForState(in: app, timeout: 3) { $0.string("tab") == target }
    }

    /// Focus lands a frame or two after the press, so poll rather than sleep.
    private func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.hasFocus { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    private func moveFocus(
        to element: XCUIElement,
        maxPresses: Int,
        move: () -> Void
    ) {
        for _ in 0..<maxPresses where !element.hasFocus {
            move()
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(element.hasFocus, "Could not focus \(element)")
    }

    /// Picks a native tvOS menu option by index. Rows below the fold are
    /// missing from the accessibility tree until scrolled in, so it cannot
    /// wait for the row. Callers assert the picker value afterwards.
    private func selectNativeMenuOption(_ title: String, in app: XCUIApplication, menuIndex: Int) {
        guard menuIndex >= 0 else {
            XCTFail("Invalid native menu index for \(title)")
            return
        }
        // Menus reopen on the current row; Up enough times to reach the first.
        for _ in 0..<24 {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.05)
        }
        for _ in 0..<menuIndex {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.1)
        }
        remote.press(.select)
    }

    /// Seeds the search query, since typing on the tvOS keyboard is one
    /// glyph at a time.
    private func launchSeededSearchApp(query: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.searchRegressionQuery", query,
        ]
        app.launch()
        return app
    }

    private func launchNavigationRegressionApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.navigationRegression", "YES",
        ]
        app.launch()
        return app
    }

    private func exerciseAudioTracks(in app: XCUIApplication) {
        let original = state(in: app).int("audio")
        let count = state(in: app).int("audioCount")
        guard count > 1 else {
            XCTFail("The audio regression fixture must expose multiple tracks")
            return
        }
        let timeBeforeSwitch = state(in: app).double("time")

        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        waitForPanelReveal()
        remote.press(.right)
        waitForState(in: app, timeout: 4) { $0.string("tab") == "video" }
        remote.press(.right)
        waitForState(in: app, timeout: 4) { $0.string("tab") == "audio" }
        remote.press(.down) // first audio row
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-audio-1" }
        let target = original == 1 ? 2 : 1
        if target == 2 {
            remote.press(.down)
            waitForState(in: app, timeout: 4) { $0.string("focus") == "track-audio-2" }
        }
        remote.press(.select)
        waitForState(in: app, timeout: 30) {
            $0.int("audio") == target && $0.int("buffering") == 0
        }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        waitForState(in: app, timeout: 8) { $0.double("time") > timeBeforeSwitch + 1 }
    }

    private func exerciseSubtitles(in app: XCUIApplication) {
        guard state(in: app).int("subtitleCount") > 0 else {
            XCTFail("The subtitle regression fixture must expose a subtitle track")
            return
        }

        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        waitForPanelReveal()
        moveRight(toTab: "subtitles", in: app)
        remote.press(.down) // Search, deliberately ahead of long track lists.
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-search" }
        let subtitleDiscoveryScreenshot = XCTAttachment(screenshot: app.screenshot())
        subtitleDiscoveryScreenshot.name = "Subtitle discovery ahead of track list"
        subtitleDiscoveryScreenshot.lifetime = .keepAlways
        add(subtitleDiscoveryScreenshot)
        remote.press(.down) // language
        remote.press(.down) // Off
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-off" }
        remote.press(.select)
        waitForState(in: app, timeout: 8) { $0.int("subtitle") == 0 }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        Thread.sleep(forTimeInterval: 0.2)

        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        waitForPanelReveal()
        remote.press(.down) // Search
        remote.press(.down) // language
        remote.press(.down) // Off
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-off" }
        remote.press(.down) // first real subtitle
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-1" }
        remote.press(.select)
        waitForState(in: app, timeout: 8) { $0.int("subtitle") == 1 }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }

        // The selected track must survive a seek's re-prime.
        let beforeSeek = state(in: app).double("time")
        remote.press(.right)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        remote.press(.select)
        waitForState(in: app, timeout: 30) {
            $0.int("scrubbing") == 0
                && $0.int("buffering") == 0
                && $0.int("subtitle") == 1
                && $0.double("time") > beforeSeek + 5
        }
    }

    private func selectFirstSubtitle(in app: XCUIApplication) {
        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        waitForPanelReveal()
        moveRight(toTab: "subtitles", in: app)
        remote.press(.down) // Search
        remote.press(.down) // language
        remote.press(.down) // Off
        remote.press(.down) // first real subtitle
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-1" }
        remote.press(.select)
        waitForState(in: app, timeout: 8) { $0.int("subtitle") == 1 }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
    }

    /// Opens the panel (or reopens it on the tab it was left on) and settles
    /// on Subtitles with the track list mounted.
    private func openSubtitleTab(in app: XCUIApplication) {
        remote.press(.down)
        waitForState(in: app, timeout: 5) { $0.int("panel") == 1 }
        waitForPanelReveal()
        moveRight(toTab: "subtitles", in: app)
        XCTAssertTrue(
            app.buttons["player.track.subtitle-off"].waitForExistence(timeout: 5),
            "the Subtitles tab must list the tracks"
        )
    }

    /// Every track row in the Subtitles tab, Off included, in list order.
    private func subtitleTrackRows(in app: XCUIApplication) -> [XCUIElement] {
        let matches = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "player.track.subtitle-")
        )
        return (0..<matches.count).map { matches.element(boundBy: $0) }
    }

    /// Walks focus to a track row and selects it: down first (the last row
    /// absorbs overshoot), then up.
    private func selectTrackRow(_ id: String, in app: XCUIApplication) {
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<12 where state(in: app).string("focus") != "track-\(id)" {
                remote.press(direction)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-\(id)" }
        remote.press(.select)
    }

    /// The load may finish before the first sample, so seeing it is not
    /// required. Ending is: idle, the track selected, no error, no
    /// "Loading …" row.
    private func assertSubtitleLoadFinishes(
        ordinal: Int,
        in app: XCUIApplication,
        stage: String
    ) {
        let loading = app.descendants(matching: .any)["player.subtitleLoad.loading"]
        let sawLoading = loading.exists
            || state(in: app).string("subtitleLoad").hasPrefix("loading")
        // Well past a sidecar fetch, and under the loader's 30 s timeout so a
        // hang fails here.
        let settled = waitForState(in: app, timeout: 20) {
            $0.string("subtitleLoad") == "idle" && $0.int("subtitle") == ordinal
        }
        XCTAssertEqual(
            settled.string("subtitleLoad"), "idle",
            "\(stage): the subtitle load never left the loading state"
        )
        XCTAssertEqual(
            settled.int("subtitle"), ordinal,
            "\(stage): the external track never became the selection"
        )
        let error = app.staticTexts["player.subtitleLoad.error"]
        XCTAssertFalse(
            error.exists,
            "\(stage): the panel reported a subtitle load error: \(error.label)"
        )
        XCTAssertFalse(
            loading.exists,
            "\(stage): the panel is still showing the Loading… row"
        )
        print("ExternalSubtitleRegression \(stage) sawLoadingState=\(sawLoading)")
    }

    /// Switches to the first embedded track and proves playback survived:
    /// selected, not buffering, playhead moving, and a cue on screen.
    private func assertEmbeddedSwitchKeepsPlaying(in app: XCUIApplication, stage: String) {
        openSubtitleTab(in: app)
        let before = state(in: app)
        selectTrackRow("subtitle-1", in: app)
        let switched = waitForState(in: app, timeout: 30) {
            $0.int("subtitle") == 1 && $0.int("buffering") == 0
        }
        XCTAssertEqual(switched.int("subtitle"), 1, "\(stage): the embedded track was not selected")
        XCTAssertEqual(switched.int("buffering"), 0, "\(stage): playback is still buffering")
        let advanced = waitForState(in: app, timeout: 20) {
            $0.double("time") > before.double("time") + 3
        }
        XCTAssertGreaterThan(
            advanced.double("time"), before.double("time") + 3,
            "\(stage): the playhead stopped after the switch. State: \(advanced.raw)"
        )
        XCTAssertEqual(
            advanced.int("stalls"), before.int("stalls"),
            "\(stage): the switch stalled playback"
        )
        remote.press(.menu)
        waitForState(in: app, timeout: 6) { $0.int("panel") == 0 }
        waitForSubtitleCue(in: app, stage: "\(stage) embedded cue")
    }

    private func waitForSubtitleCue(in app: XCUIApplication, stage: String) {
        let shown = waitForState(in: app, timeout: 30) { $0.int("subtitleVisible") == 1 }
        XCTAssertEqual(shown.int("subtitleVisible"), 1, "\(stage): no cue reached the overlay")
        XCTAssertTrue(
            app.staticTexts["player.subtitle.text"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["player.subtitle.image"].exists,
            "\(stage): the overlay reports a cue the view never rendered"
        )
    }

    /// Guards the HLS cases against silently testing something else.
    ///
    /// The simulator profile withdraws only HEVC and Dolby Vision, so the
    /// all-H.264 public demo direct-plays and never opens HLS. That lane
    /// skips; on a supplied fixture server, `DirectPlay` is a failure.
    private func requireNegotiatedTranscode(
        _ state: RegressionState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let method = state.string("method")
        guard method != "Transcode" else { return }
        guard let server = ProcessInfo.processInfo.environment["LAGOON_REGRESSION_SERVER"] else {
            throw XCTSkip("""
                Fixture server required: playback negotiated \(method), so this run \
                never opened an HLS playlist and cannot test segment boundaries. \
                The simulator regression profile still permits H.264 direct play \
                and every public-demo item is H.264. Supply a server whose content \
                must transcode through LAGOON_REGRESSION_SERVER / \
                LAGOON_REGRESSION_USER / LAGOON_REGRESSION_PASS.
                """)
        }
        XCTFail(
            """
            Fixture server \(server) negotiated \(method) instead of Transcode, \
            so the HLS transport was not exercised. State: \(state.raw)
            """,
            file: file,
            line: line
        )
        throw RegressionFixtureError(message: "fixture server did not negotiate a transcode")
    }

    private func waitForFrameLossResult(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> FrameLossRegressionResult {
        let deadline = Date().addingTimeInterval(timeout)
        let probe = app.descendants(matching: .any)["player.regression.frameLoss"]
        repeat {
            if probe.exists,
               let value = probe.value as? String,
               let result = FrameLossRegressionResult(value) {
                return result
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw RegressionFixtureError(message: "frame-loss window did not finish before timeout")
    }

    private func waitForPanelReveal() {
        // The spring is 200 ms; the rest lets focus settle on hardware.
        Thread.sleep(forTimeInterval: 0.6)
    }

    private func moveRight(toTab target: String, in app: XCUIApplication) {
        for _ in 0..<3 where state(in: app).string("tab") != target {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.15)
        }
        waitForState(in: app, timeout: 4) { $0.string("tab") == target }
    }

    private func moveLeft(toTab target: String, in app: XCUIApplication) {
        for _ in 0..<3 where state(in: app).string("tab") != target {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.15)
        }
        waitForState(in: app, timeout: 4) { $0.string("tab") == target }
    }

    private func openPlayerPanelPreview(in app: XCUIApplication) {
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 20))
        let homeTab = app.tabBars.buttons["Home"]
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let developer = app.descendants(matching: .any)["settings.category.developer"]
        XCTAssertTrue(developer.waitForExistence(timeout: 8))
        moveFocus(to: developer, maxPresses: 10) { remote.press(.down) }
        remote.press(.select)

        let componentPicker = app.descendants(matching: .any)["settings.developer.component"]
        XCTAssertTrue(componentPicker.waitForExistence(timeout: 5))
        remote.press(.right)
        remote.press(.select)
        // Asserting the value reports a stale index directly.
        selectNativeMenuOption("Player Panel", in: app, menuIndex: 10)
        let playerPanelSelection = NSPredicate(format: "value == %@", "Player Panel")
        expectation(for: playerPanelSelection, evaluatedWith: componentPicker)
        waitForExpectations(timeout: 5)

        let openPlayerPanel = app.buttons["settings.developer.playerPanel.open"]
        XCTAssertTrue(openPlayerPanel.waitForExistence(timeout: 5))
        moveFocus(to: openPlayerPanel, maxPresses: 3) { remote.press(.down) }
        remote.press(.select)
    }
}

private struct FrameLossRegressionResult {
    let lossPercent: Double
    let dropped: Int
    let frames: Int
    let corrupted: Int
    let stalls: Int
    let audioGaps: Int

    init?(_ value: String) {
        let pattern = #"([0-9.]+)% \(([0-9]+)/([0-9]+)\).*corrupt ([0-9]+).*stalls ([0-9]+).*aGaps ([0-9]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges == 7,
              let percentRange = Range(match.range(at: 1), in: value),
              let droppedRange = Range(match.range(at: 2), in: value),
              let framesRange = Range(match.range(at: 3), in: value),
              let corruptedRange = Range(match.range(at: 4), in: value),
              let stallsRange = Range(match.range(at: 5), in: value),
              let audioGapsRange = Range(match.range(at: 6), in: value),
              let lossPercent = Double(value[percentRange]),
              let dropped = Int(value[droppedRange]),
              let frames = Int(value[framesRange]),
              let corrupted = Int(value[corruptedRange]),
              let stalls = Int(value[stallsRange]),
              let audioGaps = Int(value[audioGapsRange]) else { return nil }
        self.lossPercent = lossPercent
        self.dropped = dropped
        self.frames = frames
        self.corrupted = corrupted
        self.stalls = stalls
        self.audioGaps = audioGaps
    }
}

private extension XCUIElement {
    var valueDescription: String {
        value as? String ?? ""
    }
}

#endif

import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
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
        move(.right, toTab: "subtitles", in: app)
        remote.press(.down) // Search, deliberately ahead of long track lists.
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-search" }
        attachScreenshot(of: app, named: "Subtitle discovery ahead of track list")
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
}

#endif

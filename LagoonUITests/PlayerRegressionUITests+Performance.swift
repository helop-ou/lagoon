import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
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
        move(.right, toTab: "subtitles", in: app)
        move(.left, toTab: "info", in: app)

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
        attachScreenshot(of: app, named: "Live player panel after the sweep")

        // A stalled player would make the numbers above meaningless.
        let afterSweep = state(in: app).double("time")
        waitForState(in: app, timeout: 15) { $0.double("time") > afterSweep + 1 }

        remote.press(.menu)
        waitForState(in: app, timeout: 8) { $0.int("panel") == 0 }
    }

    func testPlayerPanelPreviewPerformance() {
        let app = XCUIApplication.regression(extra: ["-debug.settingsRegression", "YES"])
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
        attachScreenshot(of: app, named: "Compact player Audio panel")
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
            let cleanup = waitForState(in: app, timeout: 10, probe: .lifecycle) {
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
        let firstCleanup = waitForState(in: app, timeout: 10, probe: .lifecycle) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(firstCleanup.int("unclean"), 0)

        // Settings must stay responsive while the first player's resources retire.
        openSettings(in: app, timeout: 5, focusStepInterval: 0.1)
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
            let cleanup = waitForState(in: app, timeout: 10, probe: .lifecycle) {
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
        let cleanup = waitForState(in: app, timeout: 10, probe: .lifecycle) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(cleanup.int("unclean"), 0)

        // After the injected delay, a cancelled startup must stay cancelled.
        Thread.sleep(forTimeInterval: 6)
        let settled = waitForState(in: app, timeout: 2, probe: .lifecycle) {
            $0.int("engines") == 0
                && $0.int("controllers") == 0
                && $0.int("demux") == 0
                && $0.int("renderers") == 0
        }
        XCTAssertEqual(settled.int("unclean"), 0)
        XCTAssertFalse(app.descendants(matching: .any)["player.regression.state"].exists)
    }

    private func openPlayerPanelPreview(in app: XCUIApplication) {
        openSettings(in: app)

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

#endif

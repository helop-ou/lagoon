import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
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
        let cleanup = waitForState(in: app, timeout: 10, probe: .lifecycle) {
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
        XCTAssertTrue(playerProbe.waitForNonExistence(timeout: 20), "the player did not dismiss")
        // The lifecycle probe exists only in Debug, and this test runs in Release.
        if app.descendants(matching: .any)["app.lifecycle.state"].exists {
            let cleanup = waitForState(in: app, timeout: 15, probe: .lifecycle) {
                $0.int("engines") == 0
                    && $0.int("controllers") == 0
                    && $0.int("demux") == 0
                    && $0.int("renderers") == 0
            }
            XCTAssertEqual(cleanup.int("unclean"), 0)
        }
        #endif
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
}

#endif

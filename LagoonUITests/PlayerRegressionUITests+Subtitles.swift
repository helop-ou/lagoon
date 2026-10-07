import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
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
        attachScreenshot(of: app, named: "External subtitle reselected")
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
        let app = XCUIApplication.regression(extra: [
            "-debug.benchSearchTerm", "Session fixture movie",
            "-debug.regressionFindPlayable", "YES",
            "-playback.autoplayMode", "off",
        ])
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

    /// Opens the panel (or reopens it on the tab it was left on) and settles
    /// on Subtitles with the track list mounted.
    private func openSubtitleTab(in app: XCUIApplication) {
        remote.press(.down)
        waitForState(in: app, timeout: 5) { $0.int("panel") == 1 }
        waitForPanelReveal()
        move(.right, toTab: "subtitles", in: app)
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
}

#endif

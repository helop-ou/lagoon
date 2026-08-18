import XCTest

final class PlayerRegressionUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPlaybackPauseScrubTracksAndSubtitles() throws {
        let app = launchPlayer(title: "300", year: 2006)
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
        waitForState(in: app, timeout: 8) {
            $0.int("scrubbing") == 0 && $0.double("time") > beforeScrub + 5
        }

        let afterForwardScrub = state(in: app).double("time")
        remote.press(.left)
        waitForState(in: app, timeout: 3) { $0.int("scrubbing") == 1 }
        remote.press(.select)
        waitForState(in: app, timeout: 8) {
            $0.int("scrubbing") == 0 && $0.double("time") < afterForwardScrub - 5
        }

        try exerciseAudioTracks(in: app)
        try exerciseSubtitles(in: app)
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
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.double("skippableEnd") > $0.double("skippableStart")
        }
        let end = state(in: app).double("skippableEnd")
        XCTAssertTrue(app.descendants(matching: .any)["player.skip"].waitForExistence(timeout: 4))
        waitForState(in: app, timeout: 12) { $0.double("time") >= end - 0.75 }
        XCTAssertFalse(app.descendants(matching: .any)["player.skip"].exists)
    }

    func testRealSubtitleCueReachesThePlayerOverlay() {
        let app = launchPlayer(title: "Pilot", series: "Young Sheldon")
        waitForState(in: app, timeout: 45) {
            $0.int("ready") == 1 && $0.int("subtitleCount") > 0 && $0.int("subtitle") > 0
        }
        waitForState(in: app, timeout: 60) { $0.int("subtitleVisible") == 1 }
        XCTAssertTrue(
            app.descendants(matching: .any)["player.subtitle.text"].exists
                || app.descendants(matching: .any)["player.subtitle.image"].exists
        )
    }

    private func exerciseAudioTracks(in app: XCUIApplication) throws {
        let original = state(in: app).int("audio")
        let count = state(in: app).int("audioCount")
        guard count > 1 else {
            throw XCTSkip("300 exposes only one audio track on this server")
        }

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
        waitForState(in: app, timeout: 8) { $0.int("audio") == target }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
        Thread.sleep(forTimeInterval: 0.2)
    }

    private func exerciseSubtitles(in app: XCUIApplication) throws {
        guard state(in: app).int("subtitleCount") > 0 else {
            throw XCTSkip("300 exposes no subtitle tracks on this server")
        }

        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        // The panel remembers Audio from the previous check.
        waitForPanelReveal()
        remote.press(.right)
        waitForState(in: app, timeout: 4) { $0.string("tab") == "subtitles" }
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
        remote.press(.down) // Off
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-off" }
        remote.press(.down) // first real subtitle
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-1" }
        remote.press(.select)
        waitForState(in: app, timeout: 8) { $0.int("subtitle") == 1 }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }

        // Actual cue decoding/rendering is covered with a known early-cue
        // episode in `testRealSubtitleCueReachesThePlayerOverlay`; this
        // movie supplies the large track list needed to verify switching.
    }

    private func launchPlayer(
        title: String,
        year: Int? = nil,
        series: String? = nil,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.benchSearchTerm", title,
            "-debug.playbackHUD", "YES",
            "-debug.matchContent", "YES",
        ]
        if let year {
            app.launchArguments += ["-debug.benchProductionYear", String(year)]
        }
        if let series {
            app.launchArguments += ["-debug.regressionSeriesName", series]
        }
        app.launchArguments += extraArguments
        app.launch()
        return app
    }

    @discardableResult
    private func waitForState(
        in app: XCUIApplication,
        timeout: TimeInterval,
        predicate: (RegressionState) -> Bool
    ) -> RegressionState {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = RegressionState("")
        repeat {
            latest = state(in: app)
            if predicate(latest) { return latest }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTFail("Timed out waiting for player state. Latest: \(latest.raw)")
        return latest
    }

    private func state(in app: XCUIApplication) -> RegressionState {
        let element = app.descendants(matching: .any)["player.regression.state"]
        guard element.exists else { return RegressionState("") }
        return RegressionState(element.value as? String ?? "")
    }

    private func waitForPanelReveal() {
        // The panel's spring is 400 ms. Focus becomes eligible only once its
        // tabs have entered the visible focus region on physical tvOS.
        Thread.sleep(forTimeInterval: 0.6)
    }
}

private struct RegressionState {
    let raw: String
    private let values: [String: String]

    init(_ raw: String) {
        self.raw = raw
        values = Dictionary(uniqueKeysWithValues: raw.split(separator: " ").compactMap { token in
            let pair = token.split(separator: "=", maxSplits: 1).map(String.init)
            return pair.count == 2 ? (pair[0], pair[1]) : nil
        })
    }

    func string(_ key: String) -> String { values[key] ?? "" }
    func int(_ key: String) -> Int { Int(values[key] ?? "") ?? -1 }
    func double(_ key: String) -> Double { Double(values[key] ?? "") ?? -1 }
}

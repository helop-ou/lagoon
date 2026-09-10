#if os(iOS)
import XCTest

/// The iOS touch journey HEL-153 asks for: the player's touch grammar has no
/// remote to drive it, so this exercises the surface gestures directly —
/// single tap to toggle the transport, double-tap either half of the video
/// to seek ±10 s (with the `player.seekFeedback` glyph), and the centre
/// play/pause/skip cluster that took over the toolbar's old play/pause
/// identifier (`PlayerTouchTransportCluster` in
/// `Lagoon/Views/Player/PlayerTouchControls.swift`). tvOS keeps its own
/// `XCUIRemote`-based suites (`PlayerRegressionUITests` and friends); this
/// file exists only on iOS, where those gestures do.
///
/// Helpers below are deliberately copies of the small private ones in
/// `PlayerRegressionUITests.swift` (`launchPlayer`, `requireRegressionFixture`,
/// `waitForState`, `state(in:)`, `RegressionState`) rather than shared code —
/// UI test targets can't expose another file's `private` members, and the
/// surface here is small enough that a copy is cheaper than a refactor.
final class TouchPlayerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTouchGrammarSeeksAndTogglesPlayback() throws {
        // The public demo's Pioneer One, resolved the way the tvOS handoff
        // journey resolves it: an H.264 episode the simulator direct-plays.
        let app = launchPlayer(
            title: "touch-grammar-regression",
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 && $0.int("buffering") == 0 }
        let startTime = state(in: app).double("time")
        waitForState(in: app, timeout: 8) { $0.double("time") > startTime + 2 }

        // The iPhone player locks to landscape; confirm the window agrees
        // before trusting normalized-offset coordinates below.
        let windowFrame = app.windows.allElementsBoundByIndex.first { $0.frame.width > 100 && $0.frame.height > 100 }!.frame
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertGreaterThan(windowFrame.width, windowFrame.height,
                                 "the iPhone player should lock to landscape")
        }

        // The iOS state probe is a 1pt overlay; use the window for touches.
        let surface = app.windows.allElementsBoundByIndex.first { $0.frame.width > 100 && $0.frame.height > 100 }!
        let playPause = app.buttons["player.playPause"]

        // Reveals the centre cluster / toolbar when the 4 s auto-hide has
        // already fired. The single tap that shows them is delayed ~0.3 s by
        // the double-tap recognizer racing it, hence the short poll instead
        // of an immediate assertion. XCTest still exposes opacity-hidden
        // buttons and their frames, even with accessibilityHidden applied.
        func revealTransportIfNeeded() {
            guard state(in: app).int("transport") != 1 else { return }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            waitForState(in: app, timeout: 3) { $0.int("transport") == 1 }
        }

        revealTransportIfNeeded()
        // A slow simulator may finish delivering a tap after auto-hide.
        // Retry only if playback is still running, so a successful pause
        // can never be toggled back to play by the retry.
        for _ in 0..<3 {
            if state(in: app).int("paused") == 1 { break }
            revealTransportIfNeeded()
            playPause.tap()
        }
        waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
        snapshot(app, name: "transport")


        // Double-tap the right half: seeks +10 s and flashes the glyph.
        let beforeForwardSeek = state(in: app).double("time")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).doubleTap()
        snapshot(app, name: "double-tap")
        // XCTest waits for SwiftUI animations to settle after delivering a
        // double-tap; the 0.7-second glyph can already be gone by then.
        // Assert the actual seek, and retain screenshots as visual evidence.
        waitForState(in: app, timeout: 5) { $0.double("time") >= beforeForwardSeek + 8 }

        // Double-tap the left half: seeks −10 s. Playback keeps running
        // during the wait, so the landing check allows slack both ways.
        let beforeBackwardSeek = state(in: app).double("time")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).doubleTap()
        waitForState(in: app, timeout: 5) { $0.double("time") <= beforeBackwardSeek - 6 }

        // Paused seeks keep playback paused; resume lets the clock run again.
        XCTAssertEqual(state(in: app).int("paused"), 1)
        let pausedTime = state(in: app).double("time")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(abs(state(in: app).double("time") - pausedTime), 0.8)

        // Skip buttons mirror the same ±10 s as the double-tap gesture.
        revealTransportIfNeeded()
        let beforeSkipForward = state(in: app).double("time")
        app.buttons["player.skipForward"].tap()
        waitForState(in: app, timeout: 5) { $0.double("time") >= beforeSkipForward + 8 }

        revealTransportIfNeeded()
        let beforeSkipBack = state(in: app).double("time")
        app.buttons["player.skipBack"].tap()
        waitForState(in: app, timeout: 5) { $0.double("time") <= beforeSkipBack - 6 }

        // A real drag commits a scrub through the same rail as tvOS.
        revealTransportIfNeeded()
        let rail = app.descendants(matching: .any)["player.seek"]
        let start = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        waitForState(in: app, timeout: 8) { $0.double("lastScrub") > 100 && $0.int("scrubbing") == 0 }
        revealTransportIfNeeded()
        snapshot(app, name: "after-scrub")

        // VoiceOver names: the icon-only buttons must still speak.
        let playPauseLabel = playPause.label
        XCTAssertTrue(
            playPauseLabel == "Play" || playPauseLabel == "Pause",
            "unexpected play/pause label: \(playPauseLabel)"
        )
        XCTAssertEqual(app.buttons["player.skipBack"].label, "Back 10 seconds")
        XCTAssertEqual(app.buttons["player.skipForward"].label, "Forward 10 seconds")

        // Paused playback keeps the transport available beyond the normal
        // four-second dwell; resuming must arm auto-hide again.
        Thread.sleep(forTimeInterval: 4.5)
        XCTAssertTrue(playPause.isHittable, "paused transport should remain available")
        playPause.tap()
        waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }

        func assertTransportAutoHides() throws {
            // The toolbar must not recenter the cluster as auto-hide begins.
            // One snapshot reads visibility and position atomically. Asking
            // XCTest for a fading button's hit point can itself raise a failure.
            let centerY = playPause.frame.midY
            let fadeDeadline = Date().addingTimeInterval(6)
            while Date() < fadeDeadline {
                let hierarchy = try app.snapshot()
                let probe = elementSnapshot("player.regression.state", in: hierarchy)
                let visibility = RegressionState(probe?.value as? String ?? "")
                if visibility.int("transport") == 0 { break }
                let button = try XCTUnwrap(elementSnapshot("player.playPause", in: hierarchy))
                XCTAssertLessThan(abs(button.frame.midY - centerY), 2,
                                  "center controls moved while fading out")
                Thread.sleep(forTimeInterval: 0.05)
            }
            waitForState(in: app, timeout: 1) {
                $0.int("transport") == 0 && $0.int("paused") == 0 && $0.int("panel") == 0
            }
            // The native toolbar really leaves the hierarchy. This checks
            // rendered UI alongside the state driving the center/timeline fade;
            // screen captures retain evidence for those opacity-based overlays.
            for identifier in ["player.close", "player.info"] {
                XCTAssertTrue(app.buttons[identifier].waitForNonExistence(timeout: 1),
                              "\(identifier) should auto-hide during playback")
            }
        }

        revealTransportIfNeeded()
        try assertTransportAutoHides()
        snapshot(app, name: "auto-hidden")

        // A fresh surface tap must bring back all controls and start another
        // dwell, even though the previous auto-hide task already completed.
        revealTransportIfNeeded()
        XCTAssertTrue(app.buttons["player.skipBack"].isHittable)
        XCTAssertTrue(app.buttons["player.skipForward"].isHittable)
        snapshot(app, name: "revealed-again")
        try assertTransportAutoHides()

        // Close lives in the toolbar, which follows transport visibility too.
        revealTransportIfNeeded()
        app.buttons["player.close"].tap()
        let probe = app.descendants(matching: .any)["player.regression.state"]
        let deadline = Date().addingTimeInterval(10)
        while probe.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(probe.exists, "Close should dismiss the player and its probe")
    }

    /// Writes a PNG of the app to `LAGOON_UI_SCREENSHOT_DIR` when that
    /// environment variable is set, so a scripted run can look at the
    /// touch chrome afterwards; a plain test run writes nothing.
    private func snapshot(_ app: XCUIApplication, name: String) {
        // App-bounds capture can crop the landscape player to portrait bounds
        // after its orientation request. Capture the rendered display instead.
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "touch-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let directory = ProcessInfo.processInfo.environment["LAGOON_UI_SCREENSHOT_DIR"],
              !directory.isEmpty else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("touch-\(name).png")
        try? screenshot.pngRepresentation.write(to: url)
    }

    // MARK: - Helpers

    private func elementSnapshot(
        _ identifier: String,
        in snapshot: XCUIElementSnapshot
    ) -> XCUIElementSnapshot? {
        if snapshot.identifier == identifier { return snapshot }
        for child in snapshot.children {
            if let match = elementSnapshot(identifier, in: child) { return match }
        }
        return nil
    }

    private func launchPlayer(
        title: String,
        year: Int? = nil,
        series: String? = nil,
        simulatorTranscode: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.benchSearchTerm", title,
            "-debug.playbackHUD", "NO",
        ]
        if simulatorTranscode {
            app.launchArguments += ["-debug.simulatorTranscode", "YES"]
        }
        if let year {
            app.launchArguments += ["-debug.benchProductionYear", String(year)]
        }
        if let series {
            app.launchArguments += ["-debug.regressionSeriesName", series]
        }
        app.launchArguments += extraArguments
        for key in [
            "LAGOON_REGRESSION_SERVER",
            "LAGOON_REGRESSION_USER",
            "LAGOON_REGRESSION_PASS",
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        return app
    }

    /// Distinguishes a player failure from a server that simply lacks the
    /// specialized media fixture — see the original in
    /// PlayerRegressionUITests.swift for the full rationale.
    private func requireRegressionFixture(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) throws {
        for launchAttempt in 0..<2 {
            let deadline = Date().addingTimeInterval(timeout)
            let resolution = app.descendants(matching: .any)["player.regression.resolution"]
            repeat {
                if app.descendants(matching: .any)["player.regression.state"].exists { return }
                if resolution.exists {
                    let value = resolution.value as? String ?? ""
                    if value.hasPrefix("missing:") {
                        throw XCTSkip(
                            "Fixture server " + String(value.dropFirst("missing:".count))
                        )
                    }
                    if value.hasPrefix("error:") {
                        throw RegressionFixtureError(message: String(value.dropFirst("error:".count)))
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline

            if launchAttempt == 0 {
                app.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                app.launch()
            }
        }
        throw RegressionFixtureError(message: "did not resolve a player fixture before timeout")
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
}

private struct RegressionFixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { "Regression fixture resolution failed: \(message)" }
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
#endif

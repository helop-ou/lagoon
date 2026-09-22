#if os(iOS)
import XCTest

/// The iOS touch gestures: tap toggles the transport, double-tap either
/// half seeks ±10 s, and the centre play/pause/skip cluster
/// (`PlayerTouchTransportCluster`).
final class TouchPlayerUITests: PlayerUITestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTouchGrammarSeeksAndTogglesPlayback() throws {
        // An H.264 episode the simulator direct-plays.
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

        // The iOS state probe is a 1pt overlay; use the window for touches.
        let surface = app.windows.allElementsBoundByIndex.first { $0.frame.width > 100 && $0.frame.height > 100 }!
        let playPause = app.buttons["player.playPause"]

        // The double-tap recognizer delays a single tap ~0.3 s, hence the poll.
        // XCTest still sees opacity-hidden buttons, so check the probe instead.
        func revealTransportIfNeeded() {
            guard state(in: app).int("transport") != 1 else { return }
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
            waitForState(in: app, timeout: 3) { $0.int("transport") == 1 }
        }

        revealTransportIfNeeded()
        // A slow simulator can land a tap after auto-hide. Retry only while
        // still playing, so a retry never undoes the pause.
        for _ in 0..<3 {
            if state(in: app).int("paused") == 1 { break }
            revealTransportIfNeeded()
            tapCenter(of: playPause)
        }
        waitForState(in: app, timeout: 5) { $0.int("paused") == 1 }
        snapshot(app, name: "transport")


        let beforeForwardSeek = state(in: app).double("time")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).doubleTap()
        snapshot(app, name: "double-tap")
        // The 0.7 s glyph may be gone before XCTest returns, so assert the seek.
        waitForState(in: app, timeout: 5) { $0.double("time") >= beforeForwardSeek + 8 }

        let beforeBackwardSeek = state(in: app).double("time")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).doubleTap()
        waitForState(in: app, timeout: 5) { $0.double("time") <= beforeBackwardSeek - 6 }

        // Seeking while paused stays paused.
        XCTAssertEqual(state(in: app).int("paused"), 1)
        let pausedTime = state(in: app).double("time")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertLessThan(abs(state(in: app).double("time") - pausedTime), 0.8)

        revealTransportIfNeeded()
        let beforeSkipForward = state(in: app).double("time")
        tapCenter(of: app.buttons["player.skipForward"])
        waitForState(in: app, timeout: 5) { $0.double("time") >= beforeSkipForward + 8 }

        revealTransportIfNeeded()
        let beforeSkipBack = state(in: app).double("time")
        tapCenter(of: app.buttons["player.skipBack"])
        waitForState(in: app, timeout: 5) { $0.double("time") <= beforeSkipBack - 6 }

        revealTransportIfNeeded()
        let rail = app.descendants(matching: .any)["player.seek"]
        let start = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = rail.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        start.press(forDuration: 0.2, thenDragTo: end)
        waitForState(in: app, timeout: 8) { $0.double("lastScrub") > 100 && $0.int("scrubbing") == 0 }
        revealTransportIfNeeded()
        snapshot(app, name: "after-scrub")

        // Icon-only buttons still need VoiceOver labels.
        let playPauseLabel = playPause.label
        XCTAssertTrue(
            playPauseLabel == "Play" || playPauseLabel == "Pause",
            "unexpected play/pause label: \(playPauseLabel)"
        )
        XCTAssertEqual(app.buttons["player.skipBack"].label, "Back 10 seconds")
        XCTAssertEqual(app.buttons["player.skipForward"].label, "Forward 10 seconds")

        // Paused, the transport outlasts the 4 s dwell; resuming re-arms auto-hide.
        Thread.sleep(forTimeInterval: 4.5)
        XCTAssertTrue(playPause.isHittable, "paused transport should remain available")
        tapCenter(of: playPause)
        waitForState(in: app, timeout: 5) { $0.int("paused") == 0 }

        func assertTransportAutoHides() throws {
            // The cluster must not move as it fades. One snapshot reads both
            // visibility and position; a fading button's hit point can fail.
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
            // The toolbar leaves the hierarchy; the opacity overlays do not.
            for identifier in ["player.close", "player.info"] {
                XCTAssertTrue(app.buttons[identifier].waitForNonExistence(timeout: 1),
                              "\(identifier) should auto-hide during playback")
            }
        }

        revealTransportIfNeeded()
        try assertTransportAutoHides()
        snapshot(app, name: "auto-hidden")

        // A tap after a completed auto-hide must reveal and hide again.
        revealTransportIfNeeded()
        XCTAssertTrue(app.buttons["player.skipBack"].isHittable)
        XCTAssertTrue(app.buttons["player.skipForward"].isHittable)
        snapshot(app, name: "revealed-again")
        try assertTransportAutoHides()

        revealTransportIfNeeded()
        app.buttons["player.close"].tap()
        let probe = app.descendants(matching: .any)["player.regression.state"]
        let deadline = Date().addingTimeInterval(10)
        while probe.exists && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertFalse(probe.exists, "Close should dismiss the player and its probe")
    }

    /// Swipe up opens the options panel; swipe down minimizes into Picture
    /// in Picture, or closes where PiP is unavailable (the simulator).
    func testSwipesOpenThePanelAndMinimize() throws {
        let app = launchPlayer(
            title: "swipe-grammar-regression",
            extraArguments: [
                "-debug.regressionFindEpisodeWithSuccessor", "YES",
                "-debug.regressionRequireDirectH264Successor", "YES",
            ]
        )
        try requireRegressionFixture(in: app)
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 && $0.int("buffering") == 0 }
        let surface = app.windows.allElementsBoundByIndex.first { $0.frame.width > 100 && $0.frame.height > 100 }!

        // Start low, clear of the toolbar and centre cluster.
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
        let tabs = app.descendants(matching: .any)["player.panel.tabs"]
        XCTAssertTrue(tabs.waitForExistence(timeout: 5), "a swipe up should open the options panel")
        snapshot(app, name: "swipe-up-panel")
        app.buttons["player.panel.close"].tap()
        XCTAssertTrue(tabs.waitForNonExistence(timeout: 5))

        let probe = app.descendants(matching: .any)["player.regression.state"]
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        XCTAssertTrue(probe.waitForNonExistence(timeout: 10), "a swipe down should minimize, which closes without PiP")
    }

    /// Presenting from inside a `NavigationStack` destination let the stack
    /// drop the destination and close the player a second later, so every
    /// screen requests playback from the tab root's host.
    func testPlayerStartedFromDetailPageStaysOpen() throws {
        let app = launchSignedIn()
        // iPad's adaptive tab controls are buttons outside a TabBar node.
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 30))
        let library = app.buttons.matching(NSPredicate(format: "label == %@", "Library")).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 10))
        library.tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.view"].waitForExistence(timeout: 15))

        let poster = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'media.poster.'"))
            .firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 25), "the library grid should list at least one title")
        let itemID = poster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        poster.tap()
        XCTAssertTrue(app.descendants(matching: .any)["detail.item.\(itemID)"].waitForExistence(timeout: 15))

        let play = app.buttons["Play"].exists ? app.buttons["Play"] : app.buttons["Resume"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "the detail page should offer Play")
        play.tap()

        let probe = app.descendants(matching: .any)["player.regression.state"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30), "the player should present")
        waitForState(in: app, timeout: 45) { $0.int("ready") == 1 && $0.int("buffering") == 0 }
        let startTime = state(in: app).double("time")
        // Several times longer than the teardown took to fire.
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(probe.exists, "the player should still be up after its presentation settles")
        XCTAssertGreaterThan(state(in: app).double("time"), startTime, "playback should still be advancing")
        snapshot(app, name: "detail-page-player")
    }

    /// Also writes a PNG to `LAGOON_UI_SCREENSHOT_DIR` when it is set.
    private func snapshot(_ app: XCUIApplication, name: String) {
        // An app capture can crop the landscape player to portrait bounds.
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

    private func tapCenter(of button: XCUIElement) {
        // XCTest's activation point can fall outside a circular contentShape.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

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
}
#endif

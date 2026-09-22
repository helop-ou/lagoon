import XCTest

@MainActor
final class SubtitleDownloadUITests: XCTestCase {
    func testFailedAndOversizedSubtitlesKeepCaptionsAndPlaybackWhileRetryRecovers() async throws {
        guard let address = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              let server = URL(string: address), server.host == "127.0.0.1" else {
            throw XCTSkip("Requires the synthetic subtitle download fixture")
        }
        continueAfterFailure = false
        try await control(server, path: "reset")
        let app = XCUIApplication()
        app.launchArguments = ["-debug.playerRegression", "YES", "-debug.regressionBootstrapPublicDemo", "YES",
                               "-debug.benchSearchTerm", "Session fixture movie", "-debug.regressionFindPlayable", "YES",
                               "-playback.autoplayMode", "off", "-accounts", "()", "-session.activeAccountId", ""]
        app.launchEnvironment = ["LAGOON_REGRESSION_SERVER": address,
                                 "LAGOON_REGRESSION_USER": "Fixture viewer", "LAGOON_REGRESSION_PASS": ""]
        app.launch()
        let probe = app.descendants(matching: .any)["player.regression.state"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30))
        expect(probe) { ($0.value as? String)?.contains("ready=1") == true }
        let initialTime = time(probe)

        openSubtitles(in: app)
        select(app.buttons["player.track.subtitle-1"], in: app)
        closePanel(in: app)
        let caption = app.staticTexts["player.subtitle.text"]
        expect(caption) { $0.exists && $0.label == "Working captions" }
        attach(app, name: "subtitles-working")

        openSubtitles(in: app)
        select(app.buttons["player.track.subtitle-2"], in: app)
        let error = app.staticTexts["player.subtitleLoad.error"]
        expect(error) { $0.exists && $0.label.contains("500") }
        attach(app, name: "subtitle-server-error-and-retry")
        closePanel(in: app)
        XCTAssertEqual(caption.label, "Working captions")
        XCTAssertTrue(app.descendants(matching: .any)["player.subtitleLoad.notice"].firstMatch.exists)
        #if os(tvOS)
        XCTAssertFalse(app.staticTexts["Swipe down for Info"].exists)
        #endif
        attach(app, name: "subtitle-error-retains-working-captions")

        try await control(server, path: "subtitle-recover")
        openSubtitles(in: app)
        select(app.buttons["player.subtitleLoad.retry"], in: app)
        expect(error) { !$0.exists }
        closePanel(in: app)
        expect(caption) { $0.exists && $0.label == "Recovered captions" }
        attach(app, name: "subtitle-retry-recovered")

        openSubtitles(in: app)
        select(app.buttons["player.track.subtitle-3"], in: app)
        expect(error) { $0.exists && $0.label.contains("8 MB") }
        attach(app, name: "subtitle-compressed-oversize-rejected")
        closePanel(in: app)
        XCTAssertEqual(caption.label, "Recovered captions")
        XCTAssertGreaterThan(time(probe), initialTime + 2, "Subtitle failures must not stop video playback")

        openSubtitles(in: app)
        select(app.buttons["player.track.subtitle-off"], in: app)
        closePanel(in: app)
        expect(caption) { !$0.exists }
        XCTAssertFalse(app.descendants(matching: .any)["player.subtitleLoad.notice"].firstMatch.exists)
        attach(app, name: "subtitles-off-clears-error")
        app.terminate()
    }

    private func openSubtitles(in app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.down)
        let probe = app.descendants(matching: .any)["player.regression.state"]
        expect(probe) { ($0.value as? String)?.contains("panel=1") == true }
        let tab = app.buttons["player.tab.subtitles"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        // Focus alone switches tabs; Select could activate a track.
        let tracks = app.buttons["player.track.subtitle-off"]
        for _ in 0..<4 where !tracks.exists { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tracks.waitForExistence(timeout: 5))
        #else
        let info = app.buttons["player.info"]
        for _ in 0..<3 {
            if info.exists && info.isHittable {
                info.tap()
                break
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let tab = app.buttons["player.tab.subtitles"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.exists && grabber.frame.midY > app.frame.height * 0.3 {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        #endif
    }

    private func closePanel(in app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["player.panel.close"].tap()
        #endif
    }

    private func select(_ button: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        #if os(tvOS)
        var trace: [String] = []
        let probe = app.descendants(matching: .any)["player.regression.state"]
        for direction in [XCUIRemote.Button.down, .up] {
            for _ in 0..<15 where !hasFocus(button, in: app) {
                trace.append("\(direction): \(probe.value as? String ?? "missing")")
                XCUIRemote.shared.press(direction)
            }
        }
        if !hasFocus(button, in: app) {
            let hierarchy = XCTAttachment(string: trace.joined(separator: "\n") + "\n" + app.debugDescription)
            hierarchy.name = "subtitle-focus-hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(hasFocus(button, in: app))
        XCUIRemote.shared.press(.select)
        #else
        for _ in 0..<4 where !button.isHittable || button.frame.maxY > app.frame.maxY - 40 {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
        #endif
    }

    #if os(tvOS)
    private func hasFocus(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        guard element.exists else { return false }
        if element.hasFocus { return true }
        // XCTest reports no focus for this conditionally inserted button, so
        // read the probe; the assertions after Select check the real action.
        guard element.identifier == "player.subtitleLoad.retry" else { return false }
        let value = app.descendants(matching: .any)["player.regression.state"].value as? String ?? ""
        return value.split(separator: " ").contains("focus=track-subtitle-retry")
    }
    #endif

    private func expect(_ element: XCUIElement, condition: @escaping (XCUIElement) -> Bool) {
        let predicate = NSPredicate { object, _ in (object as? XCUIElement).map(condition) ?? false }
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: 15)
    }

    private func time(_ probe: XCUIElement) -> Double {
        let pair = (probe.value as? String ?? "").split(separator: " ").first { $0.hasPrefix("time=") }
        return Double(pair?.dropFirst(5) ?? "") ?? 0
    }

    private func control(_ server: URL, path: String) async throws {
        var request = URLRequest(url: server.appendingPathComponent("__fixture/" + path))
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

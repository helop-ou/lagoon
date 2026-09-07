import XCTest

/// Controlled local fixture: scripts/jellyfin-regression-fixture.py. Public
/// demo credentials must never be revoked by a regression test.
@MainActor
final class SessionExpiryUITests: XCTestCase {
    func testDirectPlaybackRecoversAfterRemoteRevocation() async throws {
        try await exerciseRecovery(mode: "direct", playMethod: "DirectPlay")
    }

    func testNativeHLSRecoversAfterRemoteRevocation() async throws {
        try await exerciseRecovery(mode: "hls", playMethod: "Transcode")
    }

    private func exerciseRecovery(mode: String, playMethod: String) async throws {
        guard let address = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              let server = URL(string: address), server.host == "127.0.0.1" else {
            throw XCTSkip("Requires the loopback synthetic session fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        try await control(server, path: "reset?mode=\(mode)")
        app.launchArguments = [
            "-debug.playerRegression", "YES", "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.benchSearchTerm", "Session fixture movie", "-debug.regressionFindPlayable", "YES",
            "-debug.playbackHUD", "YES", "-playback.autoplayMode", "off",
            // Each case starts without a restored identity. Only this app's
            // launch-domain defaults are overridden; no user account is touched.
            "-accounts", "()", "-session.activeAccountId", "",
        ]
        app.launchEnvironment = ["LAGOON_REGRESSION_SERVER": address,
                                 "LAGOON_REGRESSION_USER": "Fixture viewer", "LAGOON_REGRESSION_PASS": ""]
        app.launch()
        let probe = app.descendants(matching: .any)["player.regression.state"]
        XCTAssertTrue(probe.waitForExistence(timeout: 30))
        waitForPlayback(probe, method: playMethod, minimumTime: 6)
        attach(app, name: "\(mode)-playing")

        try await control(server, path: "revoke")
        let notice = app.staticTexts["signin.sessionExpired"]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "Revocation should dismiss playback and show account-specific sign-in")
        XCTAssertFalse(probe.exists)
        XCTAssertEqual(app.textFields["signin.username"].value as? String, "Fixture viewer")
        attach(app, name: "\(mode)-expired")

        let submit = app.buttons["signin.submit"]
        XCTAssertTrue(submit.exists)
        #if os(tvOS)
        let remote = XCUIRemote.shared
        for _ in 0..<6 where !submit.hasFocus { remote.press(.down) }
        XCTAssertTrue(submit.hasFocus, "Sign-in must remain reachable with the remote")
        remote.press(.select)
        #else
        submit.tap()
        #endif
        XCTAssertTrue(probe.waitForExistence(timeout: 30))
        waitForPlayback(probe, method: playMethod, minimumTime: 3)
        XCTAssertFalse(notice.exists)
        attach(app, name: "\(mode)-reauthenticated")

        let (data, _) = try await URLSession.shared.data(from: server.appendingPathComponent("__fixture/state"))
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(state["generation"] as? Int, 2, "Reauthentication must obtain a replacement token")
        let requests = try XCTUnwrap(state["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.contains { $0["revoked"] as? Bool == true && ($0["path"] as? String)?.hasPrefix("/Sessions/") == true })
        if mode == "hls" {
            XCTAssertTrue(requests.contains { ($0["path"] as? String) == "/media/variant1.m4s" }, "HLS must cross a segment boundary")
        } else {
            XCTAssertTrue(requests.contains { ($0["path"] as? String) == "/Videos/fixture/stream" })
        }
        app.terminate()
    }

    private func control(_ server: URL, path: String) async throws {
        var request = URLRequest(url: URL(string: "\(server.absoluteString)/__fixture/\(path)")!)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitForPlayback(_ probe: XCUIElement, method: String, minimumTime: Double) {
        let predicate = NSPredicate { element, _ in
            guard let raw = (element as? XCUIElement)?.value as? String else { return false }
            let fields = Dictionary(raw.split(separator: " ").compactMap { token -> (String, String)? in
                let pair = token.split(separator: "=", maxSplits: 1)
                return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
            }, uniquingKeysWith: { _, latest in latest })
            return fields["ready"] == "1" && fields["buffering"] == "0"
                && fields["method"] == method && (Double(fields["time"] ?? "") ?? 0) >= minimumTime
        }
        expectation(for: predicate, evaluatedWith: probe)
        waitForExpectations(timeout: 35)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

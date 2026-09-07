import XCTest

/// Tests Lagoon's response to a denial diagnosis. The system prompt and
/// Network.framework's real denial require physical iPhone/iPad acceptance.
@MainActor
final class LocalNetworkUITests: XCTestCase {
    func testDeniedConnectionKeepsAddressAndCanRetryAfterSettings() async throws {
        #if os(iOS)
        guard let address = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              let server = URL(string: address), server.host == "127.0.0.1" else {
            throw XCTSkip("Requires the synthetic loopback fixture")
        }
        continueAfterFailure = false
        try await control(server, path: "reset")
        try await control(server, path: "connectivity?drop=1")
        let app = XCUIApplication()
        app.launchArguments = ["-accounts", "()", "-server.url", "", "-session.activeAccountId", "",
                               "-debug.regressionBootstrapPublicDemo", "NO"]
        app.launchEnvironment = ["LAGOON_TEST_DENIED_ORIGIN": address]
        app.launch()
        let field = app.textFields["server.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(address + "\n")
        let settings = app.buttons["network.openSettings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 25))
        XCTAssertEqual(field.value as? String, address)
        XCTAssertTrue(app.buttons["server.connect"].isEnabled)
        attach(app, name: "local-network-denied")
        settings.tap()
        let settingsApp = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(settingsApp.wait(for: .runningForeground, timeout: 10))
        // No privacy toggle exists on Simulator. Restore the fixture and
        // return exactly as a viewer does after enabling access on a device.
        try await control(server, path: "connectivity?drop=0")
        app.activate()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, address)
        app.buttons["server.connect"].tap()
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 10))
        XCTAssertFalse(settings.exists)
        attach(app, name: "local-network-recovered")

        let username = app.textFields["signin.username"]
        username.tap()
        username.typeText("Fixture viewer\n")
        app.buttons["signin.submit"].tap()
        openSeerr(in: app)
        try await control(server, path: "connectivity?drop=1")
        let seerrAddress = app.textFields["settings.seerr.server"]
        XCTAssertTrue(seerrAddress.waitForExistence(timeout: 5))
        seerrAddress.tap()
        seerrAddress.typeText(address + "\n")
        app.buttons["settings.seerr.connect"].tap()
        let retry = app.buttons["settings.seerr.retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 25))
        XCTAssertTrue(settings.exists)
        XCTAssertEqual(seerrAddress.value as? String, address)
        attach(app, name: "seerr-local-network-denied")
        try await control(server, path: "connectivity?drop=0")
        retry.tap()
        let version = app.descendants(matching: .any)["settings.seerr.version"].firstMatch
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertFalse(settings.exists)
        attach(app, name: "seerr-local-network-recovered")

        // Reopen with the actual remembered account and Seerr server. This
        // also covers retry when restoration finishes after initial prefill.
        app.terminate()
        try await control(server, path: "connectivity?drop=1")
        app.launchArguments = ["-debug.regressionBootstrapPublicDemo", "NO"]
        app.launch()
        openSeerr(in: app)
        XCTAssertTrue(retry.waitForExistence(timeout: 25))
        attach(app, name: "seerr-saved-server-denied")
        try await control(server, path: "connectivity?drop=0")
        retry.tap()
        XCTAssertTrue(version.waitForExistence(timeout: 10))
        XCTAssertFalse(settings.exists)
        attach(app, name: "seerr-saved-server-recovered")
        app.terminate()
        #else
        throw XCTSkip("tvOS has no local-network privacy permission")
        #endif
    }

    #if os(iOS)
    private func openSeerr(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        settings.tap()
        let seerr = app.buttons["settings.category.seerr"]
        XCTAssertTrue(seerr.waitForExistence(timeout: 5))
        if !seerr.isHittable { app.swipeUp() }
        seerr.tap()
    }
    #endif

    private func control(_ server: URL, path: String) async throws {
        var request = URLRequest(url: URL(string: "\(server.absoluteString)/__fixture/\(path)")!)
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

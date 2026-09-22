import XCTest

@MainActor
final class ServerAddressUITests: XCTestCase {
    func testProxyConnectionsShowTheirFullAddressAndHTTPWarningBeforeSignIn() async throws {
        guard let origin = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              let server = URL(string: origin), server.host == "127.0.0.1" else {
            throw XCTSkip("Requires the synthetic loopback fixture with proxy base paths")
        }
        continueAfterFailure = false
        var reset = URLRequest(url: server.appendingPathComponent("__fixture/reset"))
        reset.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: reset)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let jellyfin = origin + "/services/jellyfin"
        let seerr = origin + "/services/seerr"
        let app = XCUIApplication()
        app.launchArguments = cleanLaunch(server: "")
        #if os(tvOS)
        // tvOS starts at an interrupted sign-in; iOS types through setup.
        app.launchArguments = cleanLaunch(server: jellyfin)
        #endif
        app.launch()
        #if os(iOS)
        let field = app.textFields["server.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        let invalid = "ftp://127.0.0.1/base"
        field.typeText(invalid + "\n")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Enter a hostname or an HTTP")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["signin.username"].exists)
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: invalid.count) + jellyfin + "/\n")
        #endif
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 15))
        assertConnection(in: app, address: jellyfin, http: true)
        attach(app, name: "jellyfin-proxy-http-before-signin")
        #if os(tvOS)
        let password = app.secureTextFields["signin.password"]
        focus(password)
        attach(app, name: "jellyfin-http-password-focus")
        let change = app.buttons["signin.changeServer"]
        focus(change)
        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.textFields["server.address"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["-accounts", "()", "-session.activeAccountId", "",
                               "-debug.playerRegression", "YES", "-debug.regressionBootstrapPublicDemo", "YES",
                               "-debug.accountPrivacyRegression", "YES", "-seerr.server.\(jellyfin)", seerr]
        app.launchEnvironment = ["LAGOON_REGRESSION_SERVER": jellyfin,
                                 "LAGOON_REGRESSION_USER": "Fixture viewer", "LAGOON_REGRESSION_PASS": ""]
        app.launch()
        #else
        let username = app.textFields["signin.username"]
        username.tap()
        username.typeText("Fixture viewer\n")
        app.buttons["signin.submit"].tap()
        #endif
        openSeerr(in: app)
        #if os(iOS)
        let seerrField = app.textFields["settings.seerr.server"]
        XCTAssertTrue(seerrField.waitForExistence(timeout: 5))
        seerrField.tap()
        seerrField.typeText(seerr + "/api/v1/\n")
        app.buttons["settings.seerr.connect"].tap()
        #endif
        assertConnection(in: app, address: seerr, http: true)
        attach(app, name: "seerr-proxy-http-before-signin")
        #if os(tvOS)
        focus(app.buttons["settings.seerr.quickConnect"])
        attach(app, name: "seerr-http-authentication-focus")
        #endif
        app.terminate()

        // Disclosure follows the URL, even for an interrupted HTTPS sign-in.
        // The HTTP fixture does not test TLS.
        let https = jellyfin.replacingOccurrences(of: "http://", with: "https://")
        app.launchArguments = cleanLaunch(server: https)
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 10))
        assertConnection(in: app, address: https, http: false)
        attach(app, name: "jellyfin-https-before-signin")
        app.terminate()
    }

    private func cleanLaunch(server: String) -> [String] {
        ["-accounts", "()", "-server.url", server, "-server.name", "Proxy fixture", "-session.activeAccountId", "",
         "-debug.regressionBootstrapPublicDemo", "NO"]
    }

    private func assertConnection(in app: XCUIApplication, address: String, http: Bool) {
        let label = app.staticTexts["server.connectionAddress"]
        XCTAssertTrue(label.waitForExistence(timeout: 15))
        XCTAssertEqual(label.label, address)
        let warning = app.descendants(matching: .any)["server.httpWarning"].firstMatch
        if http {
            XCTAssertTrue(warning.waitForExistence(timeout: 5))
            XCTAssertTrue(warning.label.contains("Connection Not Encrypted"))
        } else {
            XCTAssertFalse(warning.exists)
        }
    }

    private func openSeerr(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20))
        #if os(tvOS)
        for _ in 0..<12 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<8 where !settings.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(settings.hasFocus)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.down)
        let category = app.buttons["settings.category.seerr"]
        focus(category)
        XCUIRemote.shared.press(.select)
        #else
        settings.tap()
        let category = app.buttons["settings.category.seerr"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        if !category.isHittable { app.swipeUp() }
        category.tap()
        #endif
    }

    #if os(tvOS)
    private func focus(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.down) }
        if !element.hasFocus { XCUIRemote.shared.press(.right) }
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.up) }
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(element.hasFocus)
    }
    #endif

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

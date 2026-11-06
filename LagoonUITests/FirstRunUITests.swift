import XCTest

/// A fresh install from the welcome to Home. The public demo is not on the
/// local network, so iOS types its address.
@MainActor
final class FirstRunUITests: XCTestCase {
    func testAFreshInstallWelcomesSearchesTheNetworkAndOffersSeerr() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-accounts", "()", "-server.url", "", "-session.activeAccountId", "",
                               "-debug.regressionBootstrapPublicDemo", "NO"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["welcome.start"].waitForExistence(timeout: 10))
        attachScreenshot(of: app, named: "welcome")
        app.leaveWelcome()

        let field = app.textFields["server.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["server.discovery.searching"].waitForExistence(timeout: 2))
        attachScreenshot(of: app, named: "server-searching")
        let found = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "server.discovered.")).firstMatch
        let retry = app.buttons["server.discovery.retry"]
        let deadline = Date.now.addingTimeInterval(15)
        while !retry.exists, !found.exists, Date.now < deadline { _ = retry.waitForExistence(timeout: 1) }
        XCTAssertTrue(retry.exists || found.exists, "The search never finished")
        attachScreenshot(of: app, named: "server-searched")

        #if os(iOS)
        field.tap()
        field.typeText("https://demo.jellyfin.org/stable\n")
        let username = app.textFields["signin.username"]
        XCTAssertTrue(username.waitForExistence(timeout: 20))
        username.tap()
        username.typeText("demo")
        app.buttons["signin.submit"].tap()
        XCTAssertTrue(app.staticTexts["seerrSetup.message"].waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "seerr-offer")
        app.skipSeerrOffer()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        attachScreenshot(of: app, named: "home")
        #endif
    }
}

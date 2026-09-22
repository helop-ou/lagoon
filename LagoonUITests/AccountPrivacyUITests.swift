import XCTest

@MainActor
final class AccountPrivacyUITests: XCTestCase {
    func testNormalPickerAndAddCancelKeepEachViewersSearchesSeparate() throws {
        guard let address = ProcessInfo.processInfo.environment["LAGOON_SESSION_FIXTURE"],
              URL(string: address)?.host == "127.0.0.1" else {
            throw XCTSkip("Requires the synthetic loopback fixture")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        for (user, term) in [("Privacy A", "A private search"), ("Privacy B", "B private search")] {
            app.terminate()
            app.launchArguments = ["-debug.playerRegression", "YES", "-debug.regressionBootstrapPublicDemo", "YES",
                                   "-debug.accountPrivacyRegression", "YES", "-session.activeAccountId", ""]
            app.launchEnvironment = ["LAGOON_REGRESSION_SERVER": address, "LAGOON_REGRESSION_USER": user,
                                     "LAGOON_REGRESSION_PASS": "", "LAGOON_REGRESSION_SEARCH": term]
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        }
        app.terminate()
        // Start at the picker without re-running the bootstrap.
        app.launchArguments = ["-debug.regressionBootstrapPublicDemo", "NO", "-session.activeAccountId", ""]
        app.launchEnvironment = [:]
        app.launch()
        chooseAccount("privacy-a", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(app.buttons["A private search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["B private search"].exists)
        attach(app, name: "account-a-searches")

        openAccountSettings(in: app)
        select(app.buttons["settings.account.switch"])
        chooseAccount("privacy-b", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(app.buttons["B private search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["A private search"].exists)
        attach(app, name: "account-b-searches")

        openAccountSettings(in: app)
        select(app.buttons["settings.account.add"])
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 5))
        attach(app, name: "account-add-draft")
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["account.setup.cancel"].tap()
        #endif
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 5))
        selectTab("Search", in: app)
        XCTAssertTrue(app.buttons["B private search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["A private search"].exists)
        attach(app, name: "account-b-after-cancel")
        app.terminate()
    }

    private func chooseAccount(_ id: String, in app: XCUIApplication) {
        let element = app.buttons["account.select.\(id)"]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        #if os(tvOS)
        for _ in 0..<3 where !element.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(element.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        element.tap()
        #endif
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        #if !os(tvOS)
        // The iOS search role collapses the other tabs; tapping restores them.
        if !tab.exists, app.tabBars.buttons.firstMatch.exists {
            app.tabBars.buttons.firstMatch.tap()
        }
        #endif
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        #if os(tvOS)
        for _ in 0..<10 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        // Start from the first tab to avoid wrapping assumptions.
        for _ in 0..<6 { XCUIRemote.shared.press(.left) }
        for _ in 0..<8 where !tab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.down)
        #else
        tab.tap()
        #endif
    }

    private func openAccountSettings(in app: XCUIApplication) {
        selectTab("Settings", in: app)
        select(app.buttons["settings.category.account"])
        #if os(tvOS)
        // Settings pages open on the back button in their left column.
        XCUIRemote.shared.press(.right)
        #endif
    }

    private func select(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        #if os(tvOS)
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.up) }
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(element.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        if !element.isHittable { XCUIApplication().swipeUp() }
        element.tap()
        #endif
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

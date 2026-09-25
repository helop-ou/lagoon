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
        attachScreenshot(of: app, named: "account-a-searches")

        openAccountSettings(in: app)
        select(app.buttons["settings.account.switch"])
        // Opened from the app, the picker marks who is watching, and Back
        // (or choosing them again on iOS) closes it without switching.
        let current = app.buttons["account.select.privacy-a"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertEqual(current.value as? String, "Current profile")
        attachScreenshot(of: app, named: "picker-from-app")
        #if os(tvOS)
        XCTAssertTrue(current.hasFocus)
        XCUIRemote.shared.press(.menu)
        #else
        current.tap()
        #endif
        XCTAssertTrue(current.waitForNonExistence(timeout: 5))
        select(app.buttons["settings.account.switch"])
        chooseAccount("privacy-b", in: app)
        selectTab("Search", in: app)
        XCTAssertTrue(app.buttons["B private search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["A private search"].exists)
        attachScreenshot(of: app, named: "account-b-searches")

        // Adding from the picker closes it first, then opens sign-in. This
        // time the picker comes from the chrome, not the Account page.
        openProfilePickerFromChrome(in: app)
        let add = app.buttons["account.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        #if os(tvOS)
        for _ in 0..<3 where !add.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(add.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        add.tap()
        #endif
        XCTAssertTrue(app.textFields["signin.username"].waitForExistence(timeout: 5))
        attachScreenshot(of: app, named: "account-add-draft")
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["account.setup.cancel"].tap()
        #endif
        XCTAssertTrue(app.tabBars.buttons["Search"].waitForExistence(timeout: 5))
        selectTab("Search", in: app)
        XCTAssertTrue(app.buttons["B private search"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["A private search"].exists)
        attachScreenshot(of: app, named: "account-b-after-cancel")
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

    /// tvOS: the profile button, Right from the last tab. iOS: Switch
    /// Profile at the top of Settings, whose tab shows the portrait.
    private func openProfilePickerFromChrome(in app: XCUIApplication) {
        selectTab("Settings", in: app)
        #if os(tvOS)
        let button = app.buttons["profile.button"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<10 where !button.hasFocus
            && !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        for _ in 0..<3 where !button.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(button.hasFocus)
        attachScreenshot(of: app, named: "profile-button-focused")
        XCUIRemote.shared.press(.select)
        #else
        attachScreenshot(of: app, named: "settings-root-profile")
        select(app.buttons["settings.root.switchProfile"])
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

}

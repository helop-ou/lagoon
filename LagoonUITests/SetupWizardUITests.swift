import XCTest

/// The first sign-in's setup, opened by the harness: four steps, each left on
/// its default with Continue alone, and then Home.
@MainActor
final class SetupWizardUITests: XCTestCase {
    func testTheSetupWalksItsFourStepsOnTheirDefaultsToHome() {
        continueAfterFailure = false
        let app = XCUIApplication.regression(extra: [
            "-debug.setupAtLaunch", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ])
        app.launch()
        defer { app.terminate() }

        let title = app.staticTexts["setup.title"]
        let position = app.staticTexts["setup.position"]
        let advance = app.buttons["setup.continue"]
        XCTAssertTrue(title.waitForExistence(timeout: 25), "The setup did not open")
        let steps = ["Choose a Look", "Sound and Subtitles", "How Subtitles Look", "Help Improve Lagoon"]
        for (index, step) in steps.enumerated() {
            let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", step), object: title)
            XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 5), .completed, "Step \(index + 1) is not \(step)")
            XCTAssertEqual(position.label, "Step \(index + 1) of \(steps.count)")
            // Back appears once there is a step to go back to.
            XCTAssertEqual(app.buttons["setup.skip"].exists, index == 0)
            XCTAssertEqual(app.buttons["setup.back"].exists, index > 0)
            attachFullScreenshot(named: "setup-\(index + 1)")
            #if os(tvOS)
            // Continue holds the focus, so Select alone walks the defaults.
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasFocus == true"), object: advance)
            XCTAssertEqual(XCTWaiter.wait(for: [focused], timeout: 5), .completed, "Continue lost the focus")
            XCUIRemote.shared.press(.select)
            #else
            advance.tap()
            #endif
        }
        let home = app.buttons.matching(NSPredicate(format: "label == %@", "Home")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 20), "The setup did not end at Home")
        XCTAssertFalse(title.exists)
    }

    #if os(iOS)
    /// A choice made in the setup is the setting itself, not a copy of it.
    func testAChoiceMadeInTheSetupIsWhatSettingsShows() {
        continueAfterFailure = false
        let app = XCUIApplication.regression(extra: [
            "-debug.setupAtLaunch", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ])
        app.launch()
        defer { app.terminate() }

        let advance = app.buttons["setup.continue"]
        XCTAssertTrue(advance.waitForExistence(timeout: 25), "The setup did not open")
        advance.tap()
        let subtitles = app.descendants(matching: .any)["setup.subtitles.default"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        subtitles.tap()
        let always = app.buttons["Always"].firstMatch
        XCTAssertTrue(always.waitForExistence(timeout: 5))
        always.tap()
        let chosen = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label CONTAINS %@", "Always", "Always"), object: subtitles
        )
        XCTAssertEqual(XCTWaiter.wait(for: [chosen], timeout: 5), .completed)
        attachFullScreenshot(named: "setup-chosen")
        advance.tap()
        advance.tap()
        advance.tap()

        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "The setup did not end at Home")
        settings.tap()
        let category = app.descendants(matching: .any)["settings.category.subtitles"]
        XCTAssertTrue(category.waitForExistence(timeout: 5))
        category.tap()
        let setting = app.descendants(matching: .any)["settings.subtitles.default"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        let kept = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label CONTAINS %@", "Always", "Always"), object: setting
        )
        XCTAssertEqual(XCTWaiter.wait(for: [kept], timeout: 5), .completed, "Settings does not show the setup's choice")
    }
    #endif
}

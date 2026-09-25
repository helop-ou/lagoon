#if os(iOS)
import XCTest

/// Exercises the category boundaries without depending on the demo catalog.
@MainActor
final class SettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCategoryBindingsSurviveNavigation() {
        let app = launchSettings()
        defer { app.terminate() }
        attachFullScreenshot(named: "settings-root")

        openCategory("playback", title: "Playback", in: app)
        let originalSkip = selectedChoice(control("settings.playback.skipMode", in: app),
                                          choices: ["Skip Automatically", "Skip Instantly", "Ask Every Time"])
        let originalAutoplay = selectedChoice(control("settings.playback.autoplayMode", in: app),
                                              choices: ["Play Automatically", "Ask Every Time", "Off"])
        let changedSkip = originalSkip == "Ask Every Time" ? "Skip Instantly" : "Ask Every Time"
        let changedAutoplay = originalAutoplay == "Off" ? "Play Automatically" : "Off"
        choose(changedSkip, for: "settings.playback.skipMode", page: "Playback", in: app)
        choose(changedAutoplay, for: "settings.playback.autoplayMode", page: "Playback", in: app)
        let cellular = app.switches["settings.playback.fullQualityOnMetered"]
        let originalCellular = toggleValue(cellular)
        tapToggle(cellular, in: app)
        expectValue(cellular, originalCellular == "1" ? "0" : "1")
        attachFullScreenshot(named: "settings-playback")
        goBack(to: "Settings", in: app)
        openCategory("playback", title: "Playback", in: app)
        expectValue(control("settings.playback.skipMode", in: app), changedSkip)
        expectValue(control("settings.playback.autoplayMode", in: app), changedAutoplay)
        expectValue(cellular, originalCellular == "1" ? "0" : "1")
        tapToggle(cellular, in: app)
        expectValue(cellular, originalCellular)
        choose(originalSkip, for: "settings.playback.skipMode", page: "Playback", in: app)
        choose(originalAutoplay, for: "settings.playback.autoplayMode", page: "Playback", in: app)
        goBack(to: "Settings", in: app)

        openCategory("audio", title: "Audio", in: app)
        choose("Original Audio", for: "settings.audio.default", page: "Audio", in: app)
        XCTAssertTrue(control("settings.audio.preferred", in: app).exists)
        XCTAssertTrue(control("settings.audio.fallback", in: app).exists)
        attachFullScreenshot(named: "settings-audio")
        goBack(to: "Settings", in: app)
        openCategory("audio", title: "Audio", in: app)
        expectValue(control("settings.audio.default", in: app), "Original Audio")
        goBack(to: "Settings", in: app)

        openCategory("subtitles", title: "Subtitles", in: app)
        choose("Smart", for: "settings.subtitles.default", page: "Subtitles", in: app)
        XCTAssertTrue(control("settings.subtitles.preferred", in: app).exists)
        XCTAssertTrue(control("settings.subtitles.fallback", in: app).exists)
        // Whatever the permission result, it must not replace the page.
        let availability = control("settings.subtitles.search", in: app)
        reveal(availability, in: app)
        attachFullScreenshot(named: "settings-subtitles")
        openAppearance(in: app)
        // Set the baseline through the UI: the tvOS regression flag resets
        // appearance whenever the Settings root reappears.
        let reset = app.buttons["settings.subtitles.reset"]
        reveal(reset, in: app)
        reset.tap()
        let systemStyle = app.switches["settings.subtitles.systemAppearance"]
        reveal(systemStyle, in: app)
        expectValue(systemStyle, "1")
        tapToggle(systemStyle, in: app)
        expectValue(systemStyle, "0")
        choose("Large", for: "settings.subtitles.size", page: "Subtitle Appearance", in: app)
        attachFullScreenshot(named: "settings-subtitle-appearance")
        goBack(to: "Subtitles", in: app)
        expectValue(control("settings.subtitles.appearance", in: app), "Lagoon")
        goBack(to: "Settings", in: app)
        openCategory("subtitles", title: "Subtitles", in: app)
        expectValue(control("settings.subtitles.default", in: app), "Smart")
        openAppearance(in: app)
        expectValue(systemStyle, "0")
        expectValue(control("settings.subtitles.size", in: app), "Large")
        reveal(reset, in: app)
        reset.tap()
        expectValue(systemStyle, "1")
        goBack(to: "Subtitles", in: app)
        goBack(to: "Settings", in: app)

        openCategory("diagnostics", title: "Advanced", in: app)
        for id in ["hud", "frameLoss", "dovi"] {
            XCTAssertTrue(app.switches["settings.diagnostics.\(id)"].exists)
        }
        let reports = app.switches["settings.diagnostics.reports"]
        reveal(reports, in: app)
        let originalReports = toggleValue(reports)
        tapToggle(reports, in: app)
        expectValue(reports, originalReports == "1" ? "0" : "1")
        attachFullScreenshot(named: "settings-diagnostics")
        goBack(to: "Settings", in: app)
        openCategory("diagnostics", title: "Advanced", in: app)
        reveal(reports, in: app)
        expectValue(reports, originalReports == "1" ? "0" : "1")
        tapToggle(reports, in: app)
        expectValue(reports, originalReports)
        goBack(to: "Settings", in: app)
    }

    func testCategoriesRemainReachableAtLargestAccessibilityTextSize() {
        let app = launchSettings(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
        defer { app.terminate() }
        attachFullScreenshot(named: "settings-accessibility-root")
        for (category, title, identifier) in [
            ("playback", "Playback", "settings.playback.fullQualityOnMetered"),
            ("audio", "Audio", "settings.audio.fallback"),
            ("subtitles", "Subtitles", "settings.subtitles.appearance"),
            ("diagnostics", "Advanced", "settings.diagnostics.reports"),
        ] {
            openCategory(category, title: title, in: app)
            let lastControl = control(identifier, in: app)
            reveal(lastControl, in: app)
            attachFullScreenshot(named: "settings-accessibility-\(category)")
            goBack(to: "Settings", in: app)
        }
    }

    func testBabyPinkThemeAndCategorizedChangelog() {
        let app = launchSettings()
        defer { app.terminate() }
        openCategory("appearance", title: "Appearance", in: app)
        let pink = app.staticTexts["Baby Pink"].firstMatch
        XCTAssertTrue(pink.waitForExistence(timeout: 5))
        pink.tap()
        attachFullScreenshot(named: "baby-pink-appearance")
        goBack(to: "Settings", in: app)
        attachFullScreenshot(named: "baby-pink-settings")

        openCategory("about", title: "About", in: app)
        app.buttons["Changelog"].tap()
        XCTAssertTrue(app.navigationBars["Changelog"].waitForExistence(timeout: 5))
        let current = control("settings.changelog.100", in: app)
        XCTAssertTrue(current.exists)
        XCTAssertTrue(app.staticTexts["New features"].firstMatch.waitForExistence(timeout: 5))
        attachFullScreenshot(named: "baby-pink-changelog")
        app.swipeUp()
        attachFullScreenshot(named: "baby-pink-changelog-scroll")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(timeout: 5))
        goBack(to: "Settings", in: app)
        openCategory("appearance", title: "Appearance", in: app)
        // Screenshot the theme after the round trip, then restore the default.
        attachFullScreenshot(named: "baby-pink-appearance-return")
        app.staticTexts["Lagoon"].firstMatch.tap()
    }

    private func launchSettings(contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication.regression(
            extra: [
                "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-UIPreferredContentSizeCategoryName", contentSize,
                // Keep report toggles away from the production diagnostics project.
                "-diagnostics.sentryDSN", "http://key@127.0.0.1:9/1",
            ],
            forwardFixtureServer: true
        )
        app.launch()
        // iPad exposes its adaptive tabs as buttons outside a TabBar element.
        let settings = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 25), "Regression account did not expose the Settings tab")
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        return app
    }

    private func openCategory(_ category: String, title: String, in app: XCUIApplication) {
        let destination = control("settings.category.\(category)", in: app)
        reveal(destination, in: app)
        destination.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func openAppearance(in app: XCUIApplication) {
        let appearance = control("settings.subtitles.appearance", in: app)
        reveal(appearance, in: app)
        appearance.tap()
        XCTAssertTrue(app.navigationBars["Subtitle Appearance"].waitForExistence(timeout: 5))
    }

    private func choose(_ choice: String, for identifier: String, page: String, in app: XCUIApplication) {
        let picker = control(identifier, in: app)
        reveal(picker, in: app)
        picker.tap()
        let option = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", choice)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        // Native navigation pickers may keep their option list open.
        if !app.navigationBars[page].waitForExistence(timeout: 2) {
            goBack(to: page, in: app)
        }
        expectValue(picker, choice)
    }

    private func goBack(to title: String, in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
    }

    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable, "Control is unreachable: \(element.identifier)")
    }

    private func toggleValue(_ element: XCUIElement) -> String {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let value = element.value as? String ?? ""
        XCTAssertTrue(value == "0" || value == "1", "Unexpected native switch value: \(value)")
        return value
    }

    private func tapToggle(_ row: XCUIElement, in app: XCUIApplication) {
        reveal(row, in: app)
        // The row's centre is its label, not the switch.
        let rowFrame = row.frame
        let target = app.switches.allElementsBoundByIndex
            .filter { rowFrame.contains($0.frame) && $0.isHittable }
            .min { $0.frame.width < $1.frame.width }
        guard let target else {
            XCTFail("No tappable switch in \(row.identifier)")
            return
        }
        target.tap()
    }

    private func selectedChoice(_ element: XCUIElement, choices: [String]) -> String {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let description = element.label + " " + (element.value as? String ?? "")
        let selected = choices.first { description.contains($0) }
        XCTAssertNotNil(selected, "Picker exposes no selected choice: \(description)")
        return selected ?? ""
    }

    private func expectValue(_ element: XCUIElement, _ value: String) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ OR label CONTAINS %@", value, value),
            object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "Expected \(element.identifier) to show \(value)")
    }

}
#endif

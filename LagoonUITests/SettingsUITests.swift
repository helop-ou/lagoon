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
        attach("settings-root")

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
        attach("settings-playback")
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
        attach("settings-audio")
        goBack(to: "Settings", in: app)
        openCategory("audio", title: "Audio", in: app)
        expectValue(control("settings.audio.default", in: app), "Original Audio")
        goBack(to: "Settings", in: app)

        openCategory("subtitles", title: "Subtitles", in: app)
        choose("Smart", for: "settings.subtitles.default", page: "Subtitles", in: app)
        XCTAssertTrue(control("settings.subtitles.preferred", in: app).exists)
        XCTAssertTrue(control("settings.subtitles.fallback", in: app).exists)
        // Availability may say available, denied, or unavailable; the server
        // permission result must not replace the page that owns its task.
        let availability = control("settings.subtitles.search", in: app)
        reveal(availability, in: app)
        attach("settings-subtitles")
        openAppearance(in: app)
        // Establish the baseline through the UI. The tvOS regression flag
        // resets appearance whenever the Settings root reappears, which
        // would erase the value this journey needs to verify persists.
        let reset = app.buttons["settings.subtitles.reset"]
        reveal(reset, in: app)
        reset.tap()
        let systemStyle = app.switches["settings.subtitles.systemAppearance"]
        reveal(systemStyle, in: app)
        expectValue(systemStyle, "1")
        tapToggle(systemStyle, in: app)
        expectValue(systemStyle, "0")
        choose("Large", for: "settings.subtitles.size", page: "Subtitle Appearance", in: app)
        attach("settings-subtitle-appearance")
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
        attach("settings-diagnostics")
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
        attach("settings-accessibility-root")
        for (category, title, identifier) in [
            ("playback", "Playback", "settings.playback.fullQualityOnMetered"),
            ("audio", "Audio", "settings.audio.fallback"),
            ("subtitles", "Subtitles", "settings.subtitles.appearance"),
            ("diagnostics", "Advanced", "settings.diagnostics.reports"),
        ] {
            openCategory(category, title: title, in: app)
            let lastControl = control(identifier, in: app)
            reveal(lastControl, in: app)
            attach("settings-accessibility-\(category)")
            goBack(to: "Settings", in: app)
        }
    }

    private func launchSettings(contentSize: String = "UICTContentSizeCategoryL") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-UIPreferredContentSizeCategoryName", contentSize,
            // A report toggle exercised by this test must not submit to
            // the production diagnostics project.
            "-diagnostics.sentryDSN", "http://key@127.0.0.1:9/1",
        ]
        for key in ["LAGOON_REGRESSION_SERVER", "LAGOON_REGRESSION_USER", "LAGOON_REGRESSION_PASS"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
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
        // SwiftUI can expose both the identified full-width row and an
        // unnamed native switch. The row's center is only its label area.
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

    private func attach(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["LAGOON_UI_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
#endif

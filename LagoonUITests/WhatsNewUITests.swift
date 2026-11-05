import XCTest

/// What's New presents itself once after a minor or major update, over
/// whichever screen the signed-in app opens on, and never again for that
/// version.
final class WhatsNewUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testAFeatureUpdatePresentsOnceAndThenStaysQuiet() {
        // Recorded by a launch of a much older version.
        let updated = launch(lastSeen: "0.0.1")
        let sheet = updated.descendants(matching: .any)["settings.whatsnew"]
        XCTAssertTrue(sheet.waitForExistence(timeout: 30), "a feature update should present What's New")
        let entry = updated.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'settings.whatsnew.'")).firstMatch
        XCTAssertTrue(entry.exists, "the sheet should show the installed build's notes")
        dismiss(sheet, in: updated)
        updated.terminate()

        // The first launch recorded this version, so the next one is quiet.
        let relaunched = launch(lastSeen: nil)
        assertStaysQuiet(relaunched, "What's New should present only once per version")
    }

    func testAPatchUpdateStaysQuiet() throws {
        let version = try XCTUnwrap(
            Bundle(for: Self.self).object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        )
        let parts = version.split(separator: ".")
        let samePatchLine = "\(parts[0]).\(parts.count > 1 ? parts[1] : "0").99"
        assertStaysQuiet(launch(lastSeen: samePatchLine), "a patch update should not present What's New")
    }

    private func launch(lastSeen: String?) -> XCUIApplication {
        var extra = ["-debug.whatsNewAtLaunch", "YES"]
        if let lastSeen { extra += ["-whatsNew.lastSeenVersion", lastSeen] }
        let app = XCUIApplication.regression(extra: extra)
        app.launch()
        return app
    }

    private func assertStaysQuiet(_ app: XCUIApplication, _ message: String) {
        defer { app.terminate() }
        let settingsTab = app.buttons.matching(NSPredicate(format: "label == %@", "Settings")).firstMatch
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 30), "the regression account did not sign in")
        // The sheet presents as the session signs in, so a few seconds is plenty.
        let sheet = app.descendants(matching: .any)["settings.whatsnew"]
        XCTAssertFalse(sheet.waitForExistence(timeout: 4), message)
    }

    private func dismiss(_ sheet: XCUIElement, in app: XCUIApplication) {
        #if os(tvOS)
        XCUIRemote.shared.press(.menu)
        #else
        app.buttons["Done"].tap()
        #endif
        let gone = NSPredicate(format: "exists == false")
        let dismissed = expectation(for: gone, evaluatedWith: sheet)
        wait(for: [dismissed], timeout: 5)
    }
}

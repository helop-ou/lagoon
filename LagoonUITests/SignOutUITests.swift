#if os(tvOS)
import XCTest

/// The Sign Out row lives on the pushed Account page, while the confirmation
/// that the row arms is attached to the settings root behind it. This pins
/// the row to actually producing its confirmation.
///
/// The test never confirms the sign-out: it runs against whatever account the
/// simulator is signed in to, and completing it would revoke that session.
@MainActor
final class SignOutUITests: XCTestCase {
    func testSignOutRowPresentsItsConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Settings"].waitForExistence(timeout: 30))

        selectTab("Settings", in: app)
        select(app.buttons["settings.category.account"])
        // Settings pages open on the back button in their left column.
        XCUIRemote.shared.press(.right)

        select(app.buttons["settings.account.signOut"])

        // Assert on Cancel: tvOS does not expose the dialog's title as a
        // static text, and "Sign Out" also names the row behind the dialog,
        // so Cancel is the only label that means the dialog is up.
        let appeared = app.buttons["Cancel"].waitForExistence(timeout: 5)
        attach(app, name: appeared ? "signout-confirmation" : "signout-no-confirmation")
        XCTAssertTrue(appeared, "Sign Out armed no confirmation, so the row does nothing")

        XCUIRemote.shared.press(.menu)
        app.terminate()
    }

    private func selectTab(_ title: String, in app: XCUIApplication) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        for _ in 0..<10 where !app.tabBars.buttons.allElementsBoundByIndex.contains(where: \.hasFocus) {
            XCUIRemote.shared.press(.up)
        }
        // Start from the first tab to avoid wrapping assumptions.
        for _ in 0..<6 { XCUIRemote.shared.press(.left) }
        for _ in 0..<8 where !tab.hasFocus { XCUIRemote.shared.press(.right) }
        XCTAssertTrue(tab.hasFocus)
        XCUIRemote.shared.press(.select)
        XCUIRemote.shared.press(.down)
    }

    private func select(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.up) }
        for _ in 0..<14 where !element.hasFocus { XCUIRemote.shared.press(.down) }
        XCTAssertTrue(element.hasFocus)
        XCUIRemote.shared.press(.select)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif

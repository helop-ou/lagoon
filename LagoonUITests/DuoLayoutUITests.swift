#if os(iOS)
import XCTest

/// A closed iPhone Duo puts the tab bar on the side, where the Search tab has
/// no field of its own until it is activated. Skips on other devices, and
/// fails on a Duo that is open, so CI cannot pass without testing anything.
@MainActor
final class DuoLayoutUITests: XCTestCase {
    private static let duoModel = "iPhone19,4"

    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == Self.duoModel else {
            throw XCTSkip("Requires an iPhone Duo simulator")
        }
    }

    func testSearchOpensItsFieldWhenTheBarsAreOnTheSide() throws {
        let app = XCUIApplication.regression(
            extra: ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"],
            forwardFixtureServer: true
        )
        app.launch()
        defer { app.terminate() }

        let search = tab("Search", in: app)
        XCTAssertTrue(search.waitForExistence(timeout: 25), "Regression account did not expose the Search tab")
        // The side bar is not exposed as a tab bar, so read its tabs' stacking.
        let home = tab("Home", in: app).frame
        let discover = tab("Discover", in: app).frame
        XCTAssertTrue(
            abs(home.midX - discover.midX) < 1 && home.midY != discover.midY,
            "The tabs are not stacked on the side. Close the Duo."
        )

        search.tap()
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5), "Search showed no field")
        attachFullScreenshot(named: "duo-closed-search")
    }

    private func tab(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
}
#endif

import XCTest

/// The steps a fresh install adds around setup, for journeys that start there.
extension XCUIApplication {
    func leaveWelcome() {
        let start = buttons["welcome.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), "A fresh install did not open on the welcome")
        #if os(tvOS)
        XCTAssertTrue(start.hasFocus)
        XCUIRemote.shared.press(.select)
        #else
        start.tap()
        #endif
    }

    #if os(iOS)
    func skipSeerrOffer() {
        let skip = buttons["seerrSetup.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "The first sign-in did not offer Seerr")
        skip.tap()
    }
    #endif
}

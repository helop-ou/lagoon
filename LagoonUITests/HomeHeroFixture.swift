import XCTest

/// The hero comes from the "latest" rails, which the public demo can have
/// empty. There a missing hero skips; on a supplied fixture server it fails.
extension XCTestCase {
    func requireHomeHero(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> XCUIElement {
        let hero = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.")
        ).firstMatch
        if hero.waitForExistence(timeout: timeout) { return hero }
        let homeLoaded = app.tabBars.buttons["Home"].exists
        guard let server = ProcessInfo.processInfo.environment["LAGOON_REGRESSION_SERVER"] else {
            throw XCTSkip("""
                Fixture server required: Home \(homeLoaded ? "loaded" : "did not load") but \
                offered no hero within \(Int(timeout)) s. The hero comes from the libraries' \
                latest-added items, which the public demo has none of between resets.
                """)
        }
        XCTFail(
            "Fixture server \(server) offered no Home hero within \(Int(timeout)) s (Home loaded: \(homeLoaded))",
            file: file,
            line: line
        )
        throw XCTSkip("no Home hero on the fixture server")
    }
}

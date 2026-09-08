import XCTest

/// Home's hero is built from the libraries' "latest" rails, so a server whose
/// recently-added lists are empty — the public demo between its periodic
/// resets, as seen on September 8 with a full library and no hero — offers
/// nothing to focus. That is a missing fixture, not a product failure, so on
/// the public demo the journeys that need a hero skip and say why; a
/// supplied fixture server is expected to have one, and its absence there
/// stays a failure (HEL-144, audit A18).
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

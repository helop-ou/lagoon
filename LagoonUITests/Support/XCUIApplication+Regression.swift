import XCTest

extension XCUIApplication {
    /// The three launch arguments every regression journey starts from,
    /// followed by whatever a test adds of its own. Forwarding the private
    /// fixture-server credentials is opt-in, since most journeys run against
    /// the public demo and never set them.
    static func regression(extra: [String] = [], forwardFixtureServer: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
        ] + extra
        if forwardFixtureServer {
            for key in [
                "LAGOON_REGRESSION_SERVER",
                "LAGOON_REGRESSION_USER",
                "LAGOON_REGRESSION_PASS",
            ] {
                if let value = ProcessInfo.processInfo.environment[key] {
                    app.launchEnvironment[key] = value
                }
            }
        }
        return app
    }
}

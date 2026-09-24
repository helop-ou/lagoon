import XCTest

/// Shared launch and probe support for the touch and Siri Remote journeys.
class PlayerUITestCase: XCTestCase {
    private var playbackHUDEnabled: Bool {
        #if os(tvOS)
        true
        #else
        // Idle waits can use up the transport's 4 s window before a gesture lands.
        false
        #endif
    }

    func launchPlayer(
        title: String,
        year: Int? = nil,
        series: String? = nil,
        simulatorTranscode: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        var arguments = ["-debug.benchSearchTerm", title]
        if let year {
            arguments += ["-debug.benchProductionYear", String(year)]
        }
        if let series {
            arguments += ["-debug.regressionSeriesName", series]
        }
        return launchSignedIn(simulatorTranscode: simulatorTranscode, extraArguments: arguments + extraArguments)
    }

    /// Launches signed in on Home with no fixture, for journeys that test the
    /// way into the player.
    func launchSignedIn(
        simulatorTranscode: Bool = true,
        extraArguments: [String] = []
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.playbackHUD", playbackHUDEnabled ? "YES" : "NO",
        ]
        if simulatorTranscode {
            app.launchArguments += ["-debug.simulatorTranscode", "YES"]
        }
        app.launchArguments += extraArguments
        for key in [
            "LAGOON_REGRESSION_SERVER",
            "LAGOON_REGRESSION_USER",
            "LAGOON_REGRESSION_PASS",
        ] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
        return app
    }

    /// Skips when the server lacks the fixture, rather than failing. The demo
    /// has no subtitle, multi-audio, chapter or intro item; supply a server
    /// through LAGOON_REGRESSION_*.
    func requireRegressionFixture(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) throws {
        func probe(_ identifier: String, in snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
            if snapshot.identifier == identifier { return snapshot }
            for child in snapshot.children {
                if let match = probe(identifier, in: child) { return match }
            }
            return nil
        }

        // A transient sign-in failure on a cold launch leaves the app on Sign
        // In with no probe, so retry once. Explicit fixture or API results
        // are final, so the retry never hides a regression.
        for launchAttempt in 0..<2 {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                // One snapshot, so a probe cannot vanish between exists and value.
                if let hierarchy = try? app.snapshot() {
                    if probe("player.regression.state", in: hierarchy) != nil { return }
                    let value = probe("player.regression.resolution", in: hierarchy)?.value as? String ?? ""
                    if value.hasPrefix("missing:") {
                        throw XCTSkip(
                            "Fixture server " + String(value.dropFirst("missing:".count))
                        )
                    }
                    if value.hasPrefix("error:") {
                        throw RegressionFixtureError(message: String(value.dropFirst("error:".count)))
                    }
                }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline

            if launchAttempt == 0 {
                app.terminate()
                Thread.sleep(forTimeInterval: 0.5)
                app.launch()
            }
        }
        throw RegressionFixtureError(message: "did not resolve a player fixture before timeout")
    }

    @discardableResult
    func waitForState(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (RegressionState) -> Bool
    ) -> RegressionState {
        pollRegressionState(
            in: app,
            identifier: "player.regression.state",
            timeout: timeout,
            // A missing probe still counts as a (empty) state to evaluate.
            evaluateWhenMissing: true,
            label: "player state",
            file: file,
            line: line,
            predicate: predicate
        )
    }

    func state(in app: XCUIApplication) -> RegressionState {
        let element = app.descendants(matching: .any)["player.regression.state"]
        guard element.exists else { return RegressionState("") }
        return RegressionState(element.value as? String ?? "")
    }

    @discardableResult
    func waitForLifecycle(
        in app: XCUIApplication,
        timeout: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (RegressionState) -> Bool
    ) -> RegressionState {
        pollRegressionState(
            in: app,
            identifier: "app.lifecycle.state",
            timeout: timeout,
            // Unlike waitForState, a missing probe is skipped rather than
            // evaluated as empty.
            evaluateWhenMissing: false,
            label: "playback lifecycle",
            file: file,
            line: line,
            predicate: predicate
        )
    }

    @discardableResult
    private func pollRegressionState(
        in app: XCUIApplication,
        identifier: String,
        timeout: TimeInterval,
        evaluateWhenMissing: Bool,
        label: String,
        file: StaticString,
        line: UInt,
        predicate: (RegressionState) -> Bool
    ) -> RegressionState {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = RegressionState("")
        repeat {
            let element = app.descendants(matching: .any)[identifier]
            if element.exists {
                latest = RegressionState(element.value as? String ?? "")
                if predicate(latest) { return latest }
            } else if evaluateWhenMissing {
                latest = RegressionState("")
                if predicate(latest) { return latest }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTFail("Timed out waiting for \(label). Latest: \(latest.raw)", file: file, line: line)
        return latest
    }
}

struct RegressionFixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { "Regression fixture resolution failed: \(message)" }
}

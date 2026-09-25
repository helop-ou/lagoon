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
        var extra = ["-debug.playbackHUD", playbackHUDEnabled ? "YES" : "NO"]
        if simulatorTranscode {
            extra += ["-debug.simulatorTranscode", "YES"]
        }
        extra += extraArguments
        let app = XCUIApplication.regression(extra: extra, forwardFixtureServer: true)
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
        probe: RegressionProbe = .player,
        file: StaticString = #filePath,
        line: UInt = #line,
        predicate: (RegressionState) -> Bool
    ) -> RegressionState {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = RegressionState("")
        repeat {
            let element = app.descendants(matching: .any)[probe.identifier]
            if element.exists {
                latest = RegressionState(element.value as? String ?? "")
                if predicate(latest) { return latest }
            } else if probe.evaluateWhenMissing {
                latest = RegressionState("")
                if predicate(latest) { return latest }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        XCTFail("Timed out waiting for \(probe.label). Latest: \(latest.raw)", file: file, line: line)
        return latest
    }

    func state(in app: XCUIApplication) -> RegressionState {
        let element = app.descendants(matching: .any)["player.regression.state"]
        guard element.exists else { return RegressionState("") }
        return RegressionState(element.value as? String ?? "")
    }
}

/// Which accessibility probe `waitForState` polls.
enum RegressionProbe {
    /// The playback probe. A missing element still counts as an (empty)
    /// state to evaluate.
    case player
    /// The app lifecycle probe. Unlike `.player`, a missing element is
    /// skipped rather than evaluated as empty.
    case lifecycle

    var identifier: String {
        switch self {
        case .player: "player.regression.state"
        case .lifecycle: "app.lifecycle.state"
        }
    }

    var evaluateWhenMissing: Bool {
        switch self {
        case .player: true
        case .lifecycle: false
        }
    }

    var label: String {
        switch self {
        case .player: "player state"
        case .lifecycle: "playback lifecycle"
        }
    }
}

struct RegressionFixtureError: LocalizedError {
    let message: String
    var errorDescription: String? { "Regression fixture resolution failed: \(message)" }
}

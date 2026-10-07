import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

final class PlayerRegressionUITests: PlayerUITestCase {
    let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Focus lands a frame or two after the press, so poll rather than sleep.
    func waitForFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.hasFocus { return true }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return false
    }

    func moveFocus(
        to element: XCUIElement,
        maxPresses: Int,
        move: () -> Void
    ) {
        for _ in 0..<maxPresses where !element.hasFocus {
            move()
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(element.hasFocus, "Could not focus \(element)")
    }

    /// Picks a native tvOS menu option by index. Rows below the fold are
    /// missing from the accessibility tree until scrolled in, so it cannot
    /// wait for the row. Callers assert the picker value afterwards.
    func selectNativeMenuOption(_ title: String, in app: XCUIApplication, menuIndex: Int) {
        guard menuIndex >= 0 else {
            XCTFail("Invalid native menu index for \(title)")
            return
        }
        // Menus reopen on the current row; Up enough times to reach the first.
        for _ in 0..<24 {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.05)
        }
        for _ in 0..<menuIndex {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.1)
        }
        remote.press(.select)
    }

    func selectFirstSubtitle(in app: XCUIApplication) {
        remote.press(.down)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 1 }
        waitForPanelReveal()
        move(.right, toTab: "subtitles", in: app)
        remote.press(.down) // Search
        remote.press(.down) // language
        remote.press(.down) // Off
        remote.press(.down) // first real subtitle
        waitForState(in: app, timeout: 4) { $0.string("focus") == "track-subtitle-1" }
        remote.press(.select)
        waitForState(in: app, timeout: 8) { $0.int("subtitle") == 1 }
        remote.press(.menu)
        waitForState(in: app, timeout: 4) { $0.int("panel") == 0 }
    }

    func waitForFrameLossResult(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) throws -> FrameLossRegressionResult {
        let deadline = Date().addingTimeInterval(timeout)
        let probe = app.descendants(matching: .any)["player.regression.frameLoss"]
        repeat {
            if probe.exists,
               let value = probe.value as? String,
               let result = FrameLossRegressionResult(value) {
                return result
            }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        throw RegressionFixtureError(message: "frame-loss window did not finish before timeout")
    }

    func waitForPanelReveal() {
        // The spring is 200 ms; the rest lets focus settle on hardware.
        Thread.sleep(forTimeInterval: 0.6)
    }

    func move(_ direction: XCUIRemote.Button, toTab target: String, in app: XCUIApplication) {
        for _ in 0..<3 where state(in: app).string("tab") != target {
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.15)
        }
        waitForState(in: app, timeout: 4) { $0.string("tab") == target }
    }
}

struct FrameLossRegressionResult {
    let lossPercent: Double
    let dropped: Int
    let frames: Int
    let corrupted: Int
    let stalls: Int
    let audioGaps: Int

    init?(_ value: String) {
        let pattern = #"([0-9.]+)% \(([0-9]+)/([0-9]+)\).*corrupt ([0-9]+).*stalls ([0-9]+).*aGaps ([0-9]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..., in: value)
              ),
              match.numberOfRanges == 7,
              let percentRange = Range(match.range(at: 1), in: value),
              let droppedRange = Range(match.range(at: 2), in: value),
              let framesRange = Range(match.range(at: 3), in: value),
              let corruptedRange = Range(match.range(at: 4), in: value),
              let stallsRange = Range(match.range(at: 5), in: value),
              let audioGapsRange = Range(match.range(at: 6), in: value),
              let lossPercent = Double(value[percentRange]),
              let dropped = Int(value[droppedRange]),
              let frames = Int(value[framesRange]),
              let corrupted = Int(value[corruptedRange]),
              let stalls = Int(value[stallsRange]),
              let audioGaps = Int(value[audioGapsRange]) else { return nil }
        self.lossPercent = lossPercent
        self.dropped = dropped
        self.frames = frames
        self.corrupted = corrupted
        self.stalls = stalls
        self.audioGaps = audioGaps
    }
}

extension XCUIElement {
    var valueDescription: String {
        value as? String ?? ""
    }
}

#endif

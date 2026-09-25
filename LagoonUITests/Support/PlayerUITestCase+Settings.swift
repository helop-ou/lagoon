#if os(tvOS)
import XCTest

extension PlayerUITestCase {
    /// Focuses the tab bar from wherever it landed, moves onto Settings and
    /// selects it.
    func openSettings(
        in app: XCUIApplication,
        timeout: TimeInterval = 20,
        focusStepInterval: TimeInterval = 0.15
    ) {
        let remote = XCUIRemote.shared
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: timeout))
        let homeTab = app.tabBars.buttons["Home"]
        for _ in 0..<8 where !homeTab.hasFocus && !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: focusStepInterval)
        }
        for _ in 0..<10 where !settingsTab.hasFocus {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(settingsTab.hasFocus, "Could not focus \(settingsTab)")
        remote.press(.select)
    }
}
#endif

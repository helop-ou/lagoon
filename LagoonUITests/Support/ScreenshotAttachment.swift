import XCTest

/// Screenshot attachments the way most UI test suites want them: named and
/// kept even on a passing run, so a regression is visible without
/// re-running the suite.
extension XCTestCase {
    func attachScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Captures the whole screen rather than the app's own window, and also
    /// writes a PNG to `LAGOON_UI_SCREENSHOT_DIR` when that is set.
    func attachFullScreenshot(named name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["LAGOON_UI_SCREENSHOT_DIR"], !directory.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}

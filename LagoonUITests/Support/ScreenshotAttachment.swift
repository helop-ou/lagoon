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
}

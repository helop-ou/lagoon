import XCTest

final class ServerSyncUITests: XCTestCase {
    func testReturningToForegroundRequestsFreshServerContent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.serverSyncRegression", "YES",
        ]
        app.launch()

        let probe = app.descendants(matching: .any)["server.sync.generation"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        let initialGeneration = Int(probe.value as? String ?? "")
        XCTAssertNotNil(initialGeneration)

        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 8))

        let deadline = Date().addingTimeInterval(8)
        repeat {
            if let value = Int(probe.value as? String ?? ""),
               let initialGeneration,
               value > initialGeneration {
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        XCTFail("Returning to the foreground did not advance the server sync generation")
    }
}

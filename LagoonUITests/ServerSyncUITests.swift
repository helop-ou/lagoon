import XCTest

final class ServerSyncUITests: XCTestCase {
    private let remote = XCUIRemote.shared

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
        if !app.wait(for: .runningBackground, timeout: 2) {
            // Depending on where tvOS restored focus, the first Menu press
            // can return from content to the tab chrome before leaving.
            XCUIRemote.shared.press(.menu)
        }
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

    func testTvOSRefreshActionSharesTopChromeWithoutDisplacingHome() {
        let app = launch(interval: 60)
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))

        let refresh = app.buttons["server.refresh.home"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 20))
        let hero = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.")
        ).firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 20))

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.exists)
        XCTAssertLessThan(refresh.frame.maxX, homeTab.frame.minX)
        XCTAssertEqual(
            refresh.frame.minX + 4,
            hero.frame.minX,
            accuracy: 2,
            "Refresh's visible glass does not share the hero's leading edge"
        )
        XCTAssertLessThan(refresh.frame.maxY, hero.frame.minY)
        XCTAssertFalse(refresh.hasFocus, "Refresh must not take initial focus")

        for _ in 0..<8 where !homeTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(homeTab.hasFocus)

        let discoverTab = app.tabBars.buttons["Discover"]
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(discoverTab.hasFocus)
        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(homeTab.hasFocus)

        for _ in 0..<8 where !refresh.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(refresh.hasFocus, "Refresh was not reachable from the tab bar")
        XCTAssertGreaterThanOrEqual(
            homeTab.frame.minX - refresh.frame.maxX,
            32,
            "Focused Refresh is too close to the Home tab"
        )
        XCTAssertEqual(
            refresh.frame.midY,
            app.tabBars.firstMatch.frame.midY,
            accuracy: 2,
            "Refresh is not vertically centered on the tab bar"
        )
        XCTAssertLessThanOrEqual(
            refresh.frame.height,
            app.tabBars.firstMatch.frame.height + 8,
            "Focused Refresh is visually taller than the tab bar"
        )

        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(
            hero.hasFocus,
            "Down from Refresh did not move directly to the hero"
        )
        remote.press(.up)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(homeTab.hasFocus, "Up from the hero no longer returned to Home")
        for _ in 0..<8 where !refresh.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(refresh.hasFocus)

        let manualProbe = app.descendants(matching: .any)["server.sync.manual.home"]
        let before = integerValue(of: manualProbe)
        remote.press(.select)
        XCTAssertTrue(waitForValue(of: manualProbe, greaterThan: before, timeout: 8))

        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(homeTab.hasFocus)
        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(hero.hasFocus)
        remote.press(.up)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(homeTab.hasFocus, "Up from Home content no longer returned to the tab bar")

        let topRefreshFrame = refresh.frame
        let topTabBarFrame = app.tabBars.firstMatch.frame
        remote.press(.down)
        for _ in 0..<4 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.5)
        let lowerRefreshFrame = refresh.frame
        let lowerTabBarFrame = app.tabBars.firstMatch.frame
        XCTAssertLessThan(lowerTabBarFrame.maxY, 0, "The test did not scroll past the top chrome")
        XCTAssertEqual(
            lowerRefreshFrame.midY - lowerTabBarFrame.midY,
            topRefreshFrame.midY - topTabBarFrame.midY,
            accuracy: 2,
            "Refresh did not remain attached to the scrolling tab bar"
        )
        XCTAssertFalse(refresh.isHittable, "Refresh remained sticky over the lower Home rails")

        for _ in 0..<20 where !homeTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(homeTab.hasFocus, "Navigating up did not restore the Home tab")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(
            refresh.frame.midY,
            topRefreshFrame.midY,
            accuracy: 2,
            "Refresh did not return with the top chrome"
        )
        for _ in 0..<8 where !refresh.hasFocus {
            remote.press(.left)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(refresh.hasFocus, "Refresh was not reachable after returning to the top")
    }

    func testRefreshKeepsItsChromeOffsetAcrossADetailRoundTrip() {
        let app = launch(interval: 60)
        let tabBar = app.tabBars.firstMatch
        let homeTab = app.tabBars.buttons["Home"]
        let refresh = app.buttons["server.refresh.home"]
        let hero = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.hero.")
        ).firstMatch

        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))
        XCTAssertTrue(refresh.waitForExistence(timeout: 20))
        XCTAssertTrue(hero.waitForExistence(timeout: 20))
        let visibleChromeDelta = refresh.frame.midY - tabBar.frame.midY

        for _ in 0..<8 where !hero.hasFocus {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(hero.hasFocus)
        // The first two optional shelves can be direct-play rows. Moving
        // further reaches the fixture's discovery shelves, whose cards open
        // details, and leaves the native top chrome well offscreen.
        for _ in 0..<12 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        let preDetailTabBarFrame = tabBar.frame
        XCTAssertLessThan(
            preDetailTabBarFrame.maxY,
            0,
            "The test did not move the native top chrome offscreen before opening a detail"
        )
        XCTAssertEqual(
            refresh.frame.midY - preDetailTabBarFrame.midY,
            visibleChromeDelta,
            accuracy: 2,
            "Refresh detached from the tab bar before the detail was opened"
        )
        remote.press(.select)
        XCTAssertTrue(
            waitForNonexistence(of: refresh, timeout: 8),
            "Refresh remained exposed over the pushed detail"
        )

        remote.press(.menu)
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 0.5)

        let returnedTabBarFrame = tabBar.frame
        XCTAssertLessThan(
            returnedTabBarFrame.maxY,
            0,
            "The detail round trip did not leave the native top chrome scrolled away"
        )
        XCTAssertEqual(
            refresh.frame.midY - returnedTabBarFrame.midY,
            visibleChromeDelta,
            accuracy: 2,
            "Refresh forgot the hidden tab bar's offset when the root page returned"
        )
        XCTAssertFalse(refresh.isHittable, "Refresh covered the hero after returning from a detail")
    }

    func testOnlyTheVisibleDestinationRefreshesOnTheIdleCadence() {
        let app = launch(interval: 1)
        let periodicProbe = app.descendants(matching: .any)["server.sync.periodic.home"]
        XCTAssertTrue(periodicProbe.waitForExistence(timeout: 20))
        XCTAssertTrue(waitForValue(of: periodicProbe, greaterThan: 0, timeout: 12))

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.waitForExistence(timeout: 5))
        for _ in 0..<8 where !settingsTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        for _ in 0..<8 where !settingsTab.hasFocus {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(settingsTab.hasFocus)
        remote.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.category.playback"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.buttons["server.refresh.home"].exists)

        // Allow any tick already crossing the tab boundary to settle, then
        // prove that the hidden Home task remains cancelled for two periods.
        Thread.sleep(forTimeInterval: 1.2)
        let hiddenCount = integerValue(of: periodicProbe)
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertEqual(integerValue(of: periodicProbe), hiddenCount)
    }

    private func launch(interval: Double) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.serverSyncRegression", "YES",
            "-debug.serverSyncIntervalSeconds", String(interval),
        ]
        app.launch()
        return app
    }

    private func integerValue(of element: XCUIElement) -> Int {
        Int(element.value as? String ?? "") ?? -1
    }

    private func waitForValue(
        of element: XCUIElement,
        greaterThan baseline: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if integerValue(of: element) > baseline { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func waitForNonexistence(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}

import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

final class ServerSyncUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    func testReturningToForegroundRequestsFreshServerContent() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.serverSyncRegression", "YES",
        ]
        app.launch()

        let probe = app.descendants(matching: .any)["server.sync.generation"]
        XCTAssertTrue(probe.waitForExistence(timeout: 20))
        let initialGeneration = Int(probe.value as? String ?? "")
        XCTAssertNotNil(initialGeneration)

        XCUIRemote.shared.press(.menu)
        if !app.wait(for: .runningBackground, timeout: 2) {
            // The first Menu press may only move focus back to the tab bar.
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

    func testTvOSRefreshActionSharesTopChromeWithoutDisplacingHome() throws {
        let app = launch(interval: 60)
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))

        let refresh = app.buttons["server.refresh.home"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 20))
        let hero = try requireHomeHero(in: app)

        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settingsTab.exists)
        XCTAssertLessThan(refresh.frame.maxX, homeTab.frame.minX)
        XCTAssertLessThan(refresh.frame.maxY, hero.frame.minY)
        XCTAssertFalse(refresh.hasFocus, "Refresh must not take initial focus")

        for _ in 0..<8 where !homeTab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(homeTab.hasFocus)
        // Measured with focus on the tab bar: a focused hero scales to 1640 pt
        // and shifts its edge 20 pt left of the resting grid line that Refresh
        // aligns to. UIKit's focus frame extends 4 pt past the glass.
        XCTAssertEqual(
            refresh.frame.minX + 4,
            hero.frame.minX,
            accuracy: 2,
            "Refresh's visible glass does not share the hero's resting leading edge"
        )

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

    /// The profile button mirrors Refresh at the top right: same size and
    /// chrome, reached Right from Settings, and Back from the picker it opens
    /// returns focus to it.
    func testTvOSProfileButtonMirrorsRefreshAndReturnsFromThePicker() throws {
        let app = launch(interval: 60)
        let tabBar = app.tabBars.firstMatch
        let homeTab = app.tabBars.buttons["Home"]
        let settingsTab = app.tabBars.buttons["Settings"]
        let profile = app.buttons["profile.button"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))
        XCTAssertTrue(profile.waitForExistence(timeout: 20))
        let hero = try requireHomeHero(in: app)
        XCTAssertFalse(profile.hasFocus, "The profile button must not take initial focus")
        XCTAssertGreaterThan(profile.frame.minX, settingsTab.frame.maxX)

        focusTabBar(app, tab: homeTab, stepping: .left)
        // Mirrors Refresh's leading alignment, measured the same way.
        XCTAssertEqual(
            profile.frame.maxX - 4,
            hero.frame.maxX,
            accuracy: 2,
            "The profile button's glass does not share the hero's resting trailing edge"
        )
        let refresh = app.buttons["server.refresh.home"]
        XCTAssertEqual(profile.frame.midY, refresh.frame.midY, accuracy: 1)
        XCTAssertEqual(profile.frame.size.height, refresh.frame.size.height, accuracy: 1)
        attachScreenshot(of: app, named: "profile-home-tab-bar")

        // Home content scrolls the chrome away; the button goes with it.
        let restingDelta = profile.frame.midY - tabBar.frame.midY
        remote.press(.down)
        for _ in 0..<4 {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.3)
        }
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertLessThan(tabBar.frame.maxY, 0, "The test did not scroll past the top chrome")
        XCTAssertEqual(profile.frame.midY - tabBar.frame.midY, restingDelta, accuracy: 2)
        XCTAssertFalse(profile.isHittable, "The profile button stayed over the lower rails")

        focusTabBar(app, tab: settingsTab, stepping: .right)
        for _ in 0..<3 where !profile.hasFocus {
            remote.press(.right)
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(profile.hasFocus, "The profile button was not reachable Right from Settings")
        XCTAssertEqual(profile.frame.midY, tabBar.frame.midY, accuracy: 2)
        XCTAssertLessThanOrEqual(profile.frame.height, tabBar.frame.height + 8)
        XCTAssertGreaterThanOrEqual(profile.frame.minX - settingsTab.frame.maxX, 32)
        attachScreenshot(of: app, named: "profile-focused")

        remote.press(.left)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(settingsTab.hasFocus, "Left from the profile button did not return to Settings")
        remote.press(.right)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(profile.hasFocus)

        // The bootstrap activates an unstored account, so this picker lists
        // no profiles; AccountPrivacyUITests covers the current profile.
        remote.press(.select)
        let add = app.buttons["account.add"]
        XCTAssertTrue(add.waitForExistence(timeout: 8), "The profile button did not open the picker")
        attachScreenshot(of: app, named: "profile-picker")

        remote.press(.menu)
        XCTAssertTrue(waitForNonexistence(of: add, timeout: 8), "Back did not close the picker")
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(profile.hasFocus, "Back from the picker did not return focus to the profile button")

        remote.press(.down)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(
            app.buttons["settings.category.playback"].hasFocus,
            "Down from the profile button did not go to Settings' first category"
        )
        attachScreenshot(of: app, named: "profile-down-into-settings")
    }

    func testRefreshKeepsItsChromeOffsetAcrossADetailRoundTrip() throws {
        let app = launch(interval: 60)
        let tabBar = app.tabBars.firstMatch
        let homeTab = app.tabBars.buttons["Home"]
        let refresh = app.buttons["server.refresh.home"]

        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))
        XCTAssertTrue(refresh.waitForExistence(timeout: 20))
        let hero = try requireHomeHero(in: app)
        let visibleChromeDelta = refresh.frame.midY - tabBar.frame.midY

        for _ in 0..<8 where !hero.hasFocus {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.15)
        }
        XCTAssertTrue(hero.hasFocus)
        // Past the first shelves, cards open details and the top chrome is offscreen.
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
        XCTAssertTrue(
            waitForNonexistence(of: app.buttons["profile.button"], timeout: 8),
            "The profile button remained exposed over the pushed detail"
        )

        remote.press(.menu)
        XCTAssertTrue(refresh.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["profile.button"].waitForExistence(timeout: 8))
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

        // Let an in-flight tick settle, then prove hidden Home stays cancelled
        // for two periods.
        Thread.sleep(forTimeInterval: 1.2)
        let hiddenCount = integerValue(of: periodicProbe)
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertEqual(integerValue(of: periodicProbe), hiddenCount)
    }

    /// A foreground bump that arrives while a tab is hidden is applied when
    /// the tab becomes visible, not at its next five-minute refresh.
    func testAForegroundBumpReachesATabThatWasHiddenWhenItArrived() {
        let app = launch(interval: 600)
        let homeTab = app.tabBars.buttons["Home"]
        let settingsTab = app.tabBars.buttons["Settings"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))

        let foregroundProbe = app.descendants(matching: .any)["server.sync.foreground.home"]
        XCTAssertTrue(foregroundProbe.waitForExistence(timeout: 20))

        focusTabBar(app, tab: settingsTab, stepping: .right)
        remote.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.category.playback"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertFalse(app.buttons["server.refresh.home"].exists)
        let baseline = integerValue(of: foregroundProbe)

        XCUIRemote.shared.press(.menu)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIRemote.shared.press(.menu)
        }
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 8))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // Still away from Home: it must not refresh while hidden.
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(
            integerValue(of: foregroundProbe),
            baseline,
            "Hidden Home refreshed while it was not the visible destination"
        )

        focusTabBar(app, tab: homeTab, stepping: .left)
        remote.press(.select)
        XCTAssertTrue(
            waitForValue(of: foregroundProbe, greaterThan: baseline, timeout: 10),
            "Returning to Home did not honour the foreground bump it missed"
        )
    }

    /// Focuses `tab` in the tab bar without selecting it.
    private func focusTabBar(
        _ app: XCUIApplication,
        tab: XCUIElement,
        stepping direction: XCUIRemote.Button
    ) {
        for _ in 0..<8 where !tab.hasFocus {
            remote.press(.up)
            Thread.sleep(forTimeInterval: 0.15)
        }
        for _ in 0..<10 where !tab.hasFocus {
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(tab.hasFocus, "Could not focus the target tab")
    }

    private func launch(interval: Double) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.regressionResetState", "YES",
            "-debug.serverSyncRegression", "YES",
            "-debug.serverSyncIntervalSeconds", String(interval),
        ]
        // A supplied fixture server has a Home hero; the demo may not.
        for key in ["LAGOON_REGRESSION_SERVER", "LAGOON_REGRESSION_USER", "LAGOON_REGRESSION_PASS"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                app.launchEnvironment[key] = value
            }
        }
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

#endif

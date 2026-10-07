import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
    /// Builds open collapsed and expand on Select, and the list still
    /// scrolls, which on tvOS means focus has somewhere to go.
    func testChangelogBuildsExpandAndCollapse() {
        let app = XCUIApplication.regression(extra: ["-debug.settingsRegression", "YES"])
        app.launch()

        openSettings(in: app)

        let about = app.descendants(matching: .any)["settings.category.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        moveFocus(to: about, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        let changelogButton = app.descendants(matching: .any)["settings.about.changelog"]
        XCTAssertTrue(changelogButton.waitForExistence(timeout: 8))
        moveFocus(to: changelogButton, maxPresses: 8) { remote.press(.right) }
        moveFocus(to: changelogButton, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        XCTAssertTrue(
            app.descendants(matching: .any)["settings.changelog"].waitForExistence(timeout: 8),
            "the changelog sheet did not open"
        )

        for build in ["55", "54", "53"] {
            let row = app.descendants(matching: .any)["settings.changelog.\(build)"]
            XCTAssertTrue(
                row.waitForExistence(timeout: 5),
                "build \(build) should have a row of its own"
            )
        }

        // Matched on a fragment: XCUITest rejects queries over 128 characters.
        let olderNote = app.staticTexts
            .matching(NSPredicate(format: "label CONTAINS %@", "your server's reason"))
            .firstMatch
        XCTAssertFalse(olderNote.exists, "a collapsed build should not show its notes")

        let build53 = app.descendants(matching: .any)["settings.changelog.53"]
        // Every newer build adds a row above 53, so the budget is generous.
        moveFocus(to: build53, maxPresses: 80) { remote.press(.down) }
        remote.press(.select)
        XCTAssertTrue(
            olderNote.waitForExistence(timeout: 5),
            "opening a build should reveal its notes"
        )

        remote.press(.select)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(olderNote.exists, "pressing again should close it")
    }

    /// Picks a theme, then navigates browse and settings. Screenshots wait
    /// for the bloom to end so they show the settled palette.
    func testBabyPinkThemeFocusBrowseAndDeepChangelogNavigation() {
        let app = XCUIApplication.regression(extra: ["-debug.settingsRegression", "YES"])
        app.launch()

        func capture(_ name: String) {
            attachScreenshot(of: app, named: name)
        }

        let homeTab = app.tabBars.buttons["Home"]
        let settingsTab = app.tabBars.buttons["Settings"]
        openSettings(in: app)

        let appearance = app.descendants(matching: .any)["settings.category.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 8))
        moveFocus(to: appearance, maxPresses: 10) { remote.press(.down) }
        remote.press(.select)
        let theme = app.descendants(matching: .any)["settings.appearance.theme"]
        // The Menu's value sits on a wrapper; the control inside owns focus.
        func themeHasFocus() -> Bool {
            theme.hasFocus || theme.descendants(matching: .any).allElementsBoundByIndex.contains(where: \.hasFocus)
        }
        func focusThemeControl() {
            for _ in 0..<3 where !themeHasFocus() {
                remote.press(.right)
                Thread.sleep(forTimeInterval: 0.2)
            }
            XCTAssertTrue(themeHasFocus(), "Could not focus Appearance's native theme control")
        }
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        focusThemeControl()
        // A profile on the default wears Spooky through October.
        let defaultTheme = Calendar.current.component(.month, from: Date()) == 10 ? "Spooky" : "Lagoon"
        XCTAssertEqual(theme.valueDescription, defaultTheme)
        remote.press(.select)
        selectNativeMenuOption("Baby Pink", in: app, menuIndex: 1)
        let pinkSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Baby Pink"), object: theme
        )
        XCTAssertEqual(XCTWaiter().wait(for: [pinkSelected], timeout: 5), .completed)
        // The bloom is hidden from accessibility; wait out its 1.7 s + 0.2 s fade.
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertTrue(themeHasFocus(), "Theme selection should preserve native control focus")
        capture("Baby Pink tvOS — settled Appearance and focused theme control")

        remote.press(.menu)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        moveFocus(to: settingsTab, maxPresses: 12) { remote.press(.up) }
        moveFocus(to: homeTab, maxPresses: 10) { remote.press(.left) }
        remote.press(.select)
        capture("Baby Pink tvOS — Home and system tab chrome")

        let genreButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.genre.")
        )
        var selectedGenre: XCUIElement?
        for _ in 0..<24 {
            selectedGenre = genreButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if selectedGenre != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let selectedGenre else {
            XCTFail("Could not focus a genre after scrolling Home in Baby Pink")
            return
        }
        capture("Baby Pink tvOS — deep Home genre shelf with native card focus")
        remote.press(.select)
        let genreLibrary = app.descendants(matching: .any)["genre.library"]
        XCTAssertTrue(genreLibrary.waitForExistence(timeout: 8))
        let populated = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != '0 items'"), object: genreLibrary
        )
        XCTAssertEqual(XCTWaiter().wait(for: [populated], timeout: 20), .completed)
        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.poster."))
        var selectedPoster: XCUIElement?
        for _ in 0..<8 {
            selectedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if selectedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let selectedPoster else {
            XCTFail("Could not focus a poster in the Baby Pink genre library")
            return
        }
        capture("Baby Pink tvOS — genre library and focused poster")
        let itemID = selectedPoster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        remote.press(.select)
        let detail = app.descendants(matching: .any)["detail.item.\(itemID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(detail.exists, "Detail should remain above the genre route")
        capture("Baby Pink tvOS — item detail")
        remote.press(.menu)
        XCTAssertTrue(genreLibrary.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(waitForFocus(selectedGenre), "Back should restore the selected Home genre")

        moveFocus(to: homeTab, maxPresses: 30) { remote.press(.up) }
        moveFocus(to: settingsTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)
        let about = app.descendants(matching: .any)["settings.category.about"]
        XCTAssertTrue(about.waitForExistence(timeout: 8))
        moveFocus(to: about, maxPresses: 14) { remote.press(.down) }
        remote.press(.select)
        let changelog = app.descendants(matching: .any)["settings.about.changelog"]
        XCTAssertTrue(changelog.waitForExistence(timeout: 5))
        remote.press(.right)
        if !waitForFocus(changelog, timeout: 1) {
            moveFocus(to: changelog, maxPresses: 8) { remote.press(.down) }
        }
        capture("Baby Pink tvOS — About with focused Changelog action")
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.changelog"].waitForExistence(timeout: 8))
        let build100 = app.descendants(matching: .any)["settings.changelog.100"]
        XCTAssertTrue(build100.waitForExistence(timeout: 5))
        capture("Baby Pink tvOS — Build 100 categorized release notes")

        let build53 = app.descendants(matching: .any)["settings.changelog.53"]
        moveFocus(to: build53, maxPresses: 80) { remote.press(.down) }
        remote.press(.select)
        let olderNote = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "your server's reason")
        ).firstMatch
        XCTAssertTrue(olderNote.waitForExistence(timeout: 5))
        capture("Baby Pink tvOS — deeply scrolled and expanded historical release notes")
        remote.press(.select)
        moveFocus(to: build100, maxPresses: 80) { remote.press(.up) }
        XCTAssertTrue(build100.frame.intersects(app.frame), "Returning up should reveal Build 100 again")
        remote.press(.menu)
        XCTAssertTrue(changelog.waitForExistence(timeout: 5))
        remote.press(.menu)
        XCTAssertTrue(about.waitForExistence(timeout: 5))

        moveFocus(to: appearance, maxPresses: 12) { remote.press(.up) }
        remote.press(.select)
        XCTAssertTrue(theme.waitForExistence(timeout: 5))
        focusThemeControl()
        remote.press(.select)
        selectNativeMenuOption("Lagoon", in: app, menuIndex: 0)
        let lagoonSelected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Lagoon"), object: theme
        )
        XCTAssertEqual(XCTWaiter().wait(for: [lagoonSelected], timeout: 5), .completed)
        Thread.sleep(forTimeInterval: 2.2)
        capture("Lagoon tvOS — default theme restored after navigation sweep")
    }

    func testTvOSSettingsHierarchyPickersAndHomeRowsNavigation() {
        let app = XCUIApplication.regression(extra: ["-debug.settingsRegression", "YES"])
        app.launch()

        openSettings(in: app)

        let playback = app.descendants(matching: .any)["settings.category.playback"]
        XCTAssertTrue(playback.waitForExistence(timeout: 8))
        remote.press(.select)
        let skipMode = app.descendants(matching: .any)["settings.playback.skipMode"]
        XCTAssertTrue(skipMode.waitForExistence(timeout: 5))
        remote.press(.right)
        remote.press(.select)
        XCTAssertTrue(
            app.descendants(matching: .any)["Skip Automatically"].waitForExistence(timeout: 5),
            "Playback controls column was unreachable"
        )
        remote.press(.menu)
        let detailBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: detailBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)

        let audio = app.descendants(matching: .any)["settings.category.audio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 8))
        moveFocus(to: audio, maxPresses: 5) { remote.press(.down) }
        remote.press(.select)

        let defaultAudio = app.descendants(matching: .any)["settings.audio.default"]
        XCTAssertTrue(defaultAudio.waitForExistence(timeout: 5))
        let detailDescription = app.descendants(matching: .any)["settings.detail.description"]
        XCTAssertTrue(detailDescription.waitForExistence(timeout: 3))
        XCTAssertLessThan(detailDescription.frame.midX, defaultAudio.frame.minX)
        // Move into the controls column first, or Select hits Back.
        remote.press(.right)
        remote.press(.select)
        // Native tvOS menu rows are cells with labelled descendants.
        let preferredLanguage = app.descendants(matching: .any)["Preferred Language"]
        XCTAssertTrue(preferredLanguage.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(preferredLanguage.frame.minX, defaultAudio.frame.midX)
        attachScreenshot(of: app, named: "Settings split view with native audio menu")
        remote.press(.menu)
        XCTAssertTrue(defaultAudio.waitForExistence(timeout: 3))

        let back = app.descendants(matching: .any)["settings.detail.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 3))
        moveFocus(to: back, maxPresses: 5) { remote.press(.left) }
        remote.press(.select)

        let subtitles = app.descendants(matching: .any)["settings.category.subtitles"]
        XCTAssertTrue(subtitles.waitForExistence(timeout: 5))
        moveFocus(to: subtitles, maxPresses: 4) { remote.press(.down) }
        remote.press(.select)
        let appearance = app.descendants(matching: .any)["settings.subtitles.appearance"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        remote.press(.right)
        moveFocus(to: appearance, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["settings.subtitlePreview"].waitForExistence(timeout: 5))
        let systemStyle = app.descendants(matching: .any)["settings.subtitles.systemAppearance"]
        XCTAssertTrue(systemStyle.waitForExistence(timeout: 5))
        XCTAssertEqual(systemStyle.label, "Use System Caption Style")
        // A SwiftUI Toggle does not reliably report hasFocus, so prove Right
        // reached it by changing its value.
        let previousSystemStyle = systemStyle.valueDescription
        remote.press(.right)
        remote.press(.select)
        XCTAssertNotEqual(systemStyle.valueDescription, previousSystemStyle)
        attachScreenshot(of: app, named: "Subtitle Appearance native toggle without duplicate state")
        // Left must still reach Back from a control far below it.
        moveFocus(to: back, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        remote.press(.menu)

        let home = app.descendants(matching: .any)["settings.category.home"]
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        moveFocus(to: home, maxPresses: 4) { remote.press(.down) }
        remote.press(.select)
        let myList = app.descendants(matching: .any)["settings.home.row.MyList"]
        XCTAssertTrue(myList.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.home.row.lagoon.movieGenres"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.home.row.lagoon.showGenres"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertEqual(
            app.descendants(matching: .any).matching(
                NSPredicate(format: "identifier == %@", "settings.home.row.MyList")
            ).count,
            1
        )
        let nativeContinueWatching = app.descendants(matching: .any)[
            "settings.home.row.lagoon.continueWatching"
        ]
        remote.press(.right)
        moveFocus(to: nativeContinueWatching, maxPresses: 3) { remote.press(.up) }
        XCTAssertTrue(nativeContinueWatching.hasFocus)
        let previousNativeVisibility = nativeContinueWatching.valueDescription
        remote.press(.select)
        XCTAssertNotEqual(nativeContinueWatching.valueDescription, previousNativeVisibility)
        attachScreenshot(of: app, named: "Lagoon native and Home Screen Sections plugin rows")
        // Row visibility persists per account, so restore it or later tests
        // (ServerSync steps a fixed number of rows) see a different Home.
        remote.press(.select)
        XCTAssertEqual(
            nativeContinueWatching.valueDescription,
            previousNativeVisibility,
            "The native row toggle was left flipped for the next test"
        )
        // Plugin rows come after every native row, so size the press budget
        // from the rows on screen rather than a fixed count.
        let homeRowCount = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "settings.home.")
        ).count
        moveFocus(to: myList, maxPresses: homeRowCount + 4) { remote.press(.down) }
        let previousVisibility = myList.valueDescription
        remote.press(.select)
        XCTAssertNotEqual(myList.valueDescription, previousVisibility)
        // Restore it, as above.
        remote.press(.select)
        XCTAssertEqual(
            myList.valueDescription,
            previousVisibility,
            "The plugin row toggle was left flipped for the next test"
        )
        remote.press(.menu)
        XCTAssertTrue(home.waitForExistence(timeout: 5))

        let seerr = app.descendants(matching: .any)["settings.category.seerr"]
        XCTAssertTrue(seerr.waitForExistence(timeout: 5))
        moveFocus(to: seerr, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let seerrServer = app.descendants(matching: .any)["settings.seerr.server"]
        XCTAssertTrue(seerrServer.waitForExistence(timeout: 5))
        remote.press(.right)
        XCTAssertTrue(seerrServer.hasFocus, "Seerr server controls column was unreachable")
        let seerrBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: seerrBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(seerr.waitForExistence(timeout: 5))

        let developer = app.descendants(matching: .any)["settings.category.developer"]
        moveFocus(to: developer, maxPresses: 5) { remote.press(.down) }
        remote.press(.select)
        let componentPicker = app.descendants(matching: .any)["settings.developer.component"]
        XCTAssertTrue(componentPicker.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["settings.developer.preview"]
                .waitForExistence(timeout: 5)
        )
        remote.press(.right)
        attachScreenshot(of: app, named: "Debug-only player component gallery")

        remote.press(.select)
        selectNativeMenuOption("Next Episode — Card", in: app, menuIndex: 4)
        let nextEpisodeSelection = NSPredicate(format: "value == %@", "Next Episode — Card")
        expectation(for: nextEpisodeSelection, evaluatedWith: componentPicker)
        waitForExpectations(timeout: 5)
        attachScreenshot(of: app, named: "Debug-only next episode component preview")

        // The panel preview uses the real controls, so focus must reach its
        // audio rows.
        remote.press(.select)
        selectNativeMenuOption("Player Panel", in: app, menuIndex: 10)
        let playerPanelSelection = NSPredicate(format: "value == %@", "Player Panel")
        expectation(for: playerPanelSelection, evaluatedWith: componentPicker)
        waitForExpectations(timeout: 5)
        let openPlayerPanel = app.buttons["settings.developer.playerPanel.open"]
        XCTAssertTrue(openPlayerPanel.waitForExistence(timeout: 5))
        moveFocus(to: openPlayerPanel, maxPresses: 3) { remote.press(.down) }
        remote.press(.select)
        let infoTab = app.buttons["player.tab.info"]
        let audioTab = app.buttons["player.tab.audio"]
        XCTAssertTrue(infoTab.waitForExistence(timeout: 5))
        XCTAssertTrue(infoTab.hasFocus)
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(audioTab.hasFocus)
        remote.press(.down)
        let firstAudioTrack = app.buttons["player.track.audio-1"]
        XCTAssertTrue(firstAudioTrack.waitForExistence(timeout: 3))
        XCTAssertTrue(firstAudioTrack.hasFocus)
        attachScreenshot(of: app, named: "Debug-only interactive production player panel")

        remote.press(.menu)
        XCTAssertTrue(componentPicker.waitForExistence(timeout: 5))
        XCTAssertEqual(componentPicker.valueDescription, "Player Panel")
        remote.press(.menu)
        XCTAssertTrue(developer.waitForExistence(timeout: 5))

        let diagnostics = app.descendants(matching: .any)["settings.category.diagnostics"]
        moveFocus(to: diagnostics, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let hud = app.descendants(matching: .any)["settings.diagnostics.hud"]
        XCTAssertTrue(hud.waitForExistence(timeout: 5))
        XCTAssertEqual(hud.label, "Show Playback Details")
        let previousHUDValue = hud.valueDescription
        remote.press(.right)
        remote.press(.select)
        XCTAssertNotEqual(hud.valueDescription, previousHUDValue)
        attachScreenshot(of: app, named: "Diagnostics native toggle without duplicate state")
        let diagnosticsBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: diagnosticsBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))

        let account = app.descendants(matching: .any)["settings.category.account"]
        moveFocus(to: account, maxPresses: 2) { remote.press(.down) }
        remote.press(.select)
        let switchProfile = app.buttons["settings.account.switch"]
        let addAccount = app.buttons["settings.account.add"]
        XCTAssertTrue(switchProfile.waitForExistence(timeout: 5))
        // Right from Back must cross the non-focusable Connection rows and
        // land on the first action, Switch Profile.
        remote.press(.right)
        XCTAssertTrue(switchProfile.hasFocus, "Account actions column was unreachable")
        remote.press(.down)
        XCTAssertTrue(addAccount.hasFocus)
        attachScreenshot(of: app, named: "Account actions reachable past connection information")
        let accountBack = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: accountBack, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(account.waitForExistence(timeout: 5))
    }
}

#endif

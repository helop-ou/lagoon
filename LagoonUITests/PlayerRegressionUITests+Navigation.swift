import XCTest

// Siri Remote journeys, compiled out on iOS.
#if os(tvOS)

extension PlayerRegressionUITests {
    func testHomeHeroLibraryAndNestedDetailBackStacks() throws {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        XCTAssertTrue(homeTab.waitForExistence(timeout: 20))

        let hero = try requireHomeHero(in: app)
        moveFocus(to: hero, maxPresses: 8) { remote.press(.down) }
        let heroItemID = hero.identifier.replacingOccurrences(of: "home.hero.", with: "")
        remote.press(.select)

        let heroDetail = app.descendants(matching: .any)["detail.item.\(heroItemID)"]
        XCTAssertTrue(heroDetail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(heroDetail.exists, "Home hero detail did not remain the top route")
        remote.press(.menu)
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue(hero.hasFocus, "Back did not restore focus to the selected Home hero")

        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        var libraryTabs: [XCUIElement] = []
        for _ in 0..<40 {
            libraryTabs = app.tabBars.buttons.allElementsBoundByIndex.filter {
                !["Home", "Discover", "Search", "Settings"].contains($0.label)
            }
            if !libraryTabs.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let libraryTab = libraryTabs.first(where: {
            $0.label.localizedCaseInsensitiveContains("movie")
        }) ?? libraryTabs.first else {
            XCTFail("No content library tab was loaded")
            return
        }
        moveFocus(to: libraryTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let library = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier == %@", "library.view")
        ).firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 8))
        expectation(for: NSPredicate(format: "value != '0 items'"), evaluatedWith: library)
        waitForExpectations(timeout: 20)

        // Library may restore All or Shows from an earlier visit; pick Movies.
        let picker = app.descendants(matching: .any)["library.kind"]
        func pickerOwnsFocus() -> Bool {
            picker.hasFocus || picker.descendants(matching: .any)
                .allElementsBoundByIndex.contains(where: \.hasFocus)
        }
        for _ in 0..<10 where !pickerOwnsFocus() {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(pickerOwnsFocus())
        remote.press(.select)
        let all = app.cells.containing(NSPredicate(format: "label == %@", "All")).firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        moveFocus(to: all, maxPresses: 4) { remote.press(.up) }
        let movies = app.cells.containing(NSPredicate(format: "label == %@", "Movies")).firstMatch
        moveFocus(to: movies, maxPresses: 4) { remote.press(.down) }
        XCTAssertTrue(movies.hasFocus)
        remote.press(.select)
        XCTAssertTrue(movies.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Movies")

        let posters = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        XCTAssertTrue(posters.firstMatch.waitForExistence(timeout: 12))
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("No library poster received focus")
            return
        }
        let libraryItemID = focusedPoster.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        remote.press(.select)

        let firstDetail = app.descendants(matching: .any)["detail.item.\(libraryItemID)"]
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 8))
        let relatedCards = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        XCTAssertTrue(relatedCards.firstMatch.waitForExistence(timeout: 12))
        var focusedRelated: XCUIElement?
        for _ in 0..<16 {
            focusedRelated = relatedCards.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedRelated != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedRelated else {
            XCTFail("More Like This could not receive focus")
            return
        }
        let relatedID = focusedRelated.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        remote.press(.select)

        let secondDetail = app.descendants(matching: .any)["detail.item.\(relatedID)"]
        XCTAssertTrue(secondDetail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(secondDetail.exists, "Nested detail did not remain the top route")
        remote.press(.menu)
        XCTAssertTrue(firstDetail.waitForExistence(timeout: 5))
        XCTAssertFalse(secondDetail.exists)
        remote.press(.menu)
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertFalse(firstDetail.exists)
        XCTAssertTrue(focusedPoster.hasFocus, "Library focus was not restored after two details")
    }

    /// On tvOS `.searchable` draws a full keyboard, which pushes Discover's
    /// content below the fold, so search lives in its own tab.
    func testDiscoverBrowsesWithoutASearchFieldAndSearchHasItsOwnTab() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let discoverTab = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 20))
        XCTAssertTrue(app.tabBars.buttons["Search"].exists, "Search lost its tab")
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: discoverTab, maxPresses: 4) { remote.press(.right) }
        remote.press(.select)

        let discover = app.descendants(matching: .any)["seerr.discover"]
        XCTAssertTrue(discover.waitForExistence(timeout: 8))
        XCTAssertFalse(
            app.searchFields.firstMatch.exists,
            "Discover is browsing behind a keyboard again"
        )
    }

    /// Back from a result returns to the same list, focused on the opened
    /// poster, without rebuilding the search.
    func testSearchDetailBackStackPreservesResultsAndFocus() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: searchTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        let search = app.descendants(matching: .any)["search.view"]
        XCTAssertTrue(search.waitForExistence(timeout: 8))
        expectation(
            for: NSPredicate(format: "NOT (value BEGINSWITH '0 library')"),
            evaluatedWith: search
        )
        waitForExpectations(timeout: 20)
        let resultCount = search.valueDescription

        let posters = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posters.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("No Search result received focus")
            return
        }
        let itemID = focusedPoster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        remote.press(.select)

        let detail = app.descendants(matching: .any)["detail.item.\(itemID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8))
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(detail.exists, "Search detail did not remain the top route")
        XCTAssertFalse(app.searchFields.firstMatch.exists, "Search field overlaid the detail page")
        remote.press(.menu)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        XCTAssertEqual(search.valueDescription, resultCount, "Search results were rebuilt on Back")
        XCTAssertTrue(focusedPoster.hasFocus, "Search focus was not restored to the selected result")
    }

    /// An empty search offers no See All: the page behind it would be empty,
    /// with nothing to hold focus, so Menu would quit the app.
    func testEmptySearchDropsSeeAllAndStillCarriesFocusBelowTheLibrarySection() {
        let app = launchSeededSearchApp(query: "zzqxjvw")
        let homeTab = app.tabBars.buttons["Home"]
        let searchTab = app.tabBars.buttons["Search"]
        XCTAssertTrue(searchTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: searchTab, maxPresses: 10) { remote.press(.right) }
        remote.press(.select)

        // Drawn only once the seeded query has come back empty.
        let empty = app.staticTexts["No matching movies or shows in your library."]
        XCTAssertTrue(empty.waitForExistence(timeout: 25), "The seeded query never reached its empty state")
        let seeAll = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'see all'"))
        XCTAssertEqual(seeAll.count, 0, "An empty search still offers a See All into an empty page")

        // Down must carry past the unfocusable status block to the Seerr
        // setup link (Seerr is unconfigured in this lane).
        let setUpSeerr = app.buttons["search.seerr.setup"]
        XCTAssertTrue(setUpSeerr.waitForExistence(timeout: 10))
        moveFocus(to: setUpSeerr, maxPresses: 12) { remote.press(.down) }
    }

    func testDiscoverSetupNavigationAndBackFocus() {
        let app = launchNavigationRegressionApp()
        let homeTab = app.tabBars.buttons["Home"]
        let discoverTab = app.tabBars.buttons["Discover"]
        XCTAssertTrue(discoverTab.waitForExistence(timeout: 20))
        moveFocus(to: homeTab, maxPresses: 8) { remote.press(.up) }
        moveFocus(to: discoverTab, maxPresses: 4) { remote.press(.right) }
        remote.press(.select)

        let setup = app.buttons["seerr.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 8))
        moveFocus(to: setup, maxPresses: 8) { remote.press(.down) }
        remote.press(.select)

        let server = app.descendants(matching: .any)["settings.seerr.server"]
        XCTAssertTrue(server.waitForExistence(timeout: 5))
        remote.press(.right)
        XCTAssertTrue(server.hasFocus, "Discover's Seerr setup controls were unreachable")

        let back = app.descendants(matching: .any)["settings.detail.back"]
        moveFocus(to: back, maxPresses: 2) { remote.press(.left) }
        remote.press(.select)
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        XCTAssertTrue(setup.hasFocus, "Back did not restore focus to Set Up Seerr")
    }

    func testNativeGenreShelfDetailNavigationAndBackStack() {
        let app = XCUIApplication.regression()
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 20))
        let genreButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "home.genre.")
        )

        var focusedGenre: XCUIElement?
        for _ in 0..<20 {
            focusedGenre = genreButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedGenre != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.25)
        }

        guard var selectedGenreButton = focusedGenre else {
            XCTFail("Could not focus a card in the native Genres shelf")
            return
        }
        // Prefer Action when the demo has it; any genre takes the same path.
        let actionGenre = genreButtons.matching(
            NSPredicate(format: "label ==[c] %@", "Action genre")
        ).firstMatch
        if actionGenre.exists {
            moveFocus(to: actionGenre, maxPresses: 24) {
                remote.press(.right)
            }
            selectedGenreButton = actionGenre
        }

        let selectedGenre = selectedGenreButton.label
        attachScreenshot(of: app, named: "Native Genres shelf — \(selectedGenre) focused")
        remote.press(.select)

        let library = app.descendants(matching: .any)["genre.library"]
        XCTAssertTrue(library.waitForExistence(timeout: 8), "Did not open \(selectedGenre)")
        let title = app.descendants(matching: .any)["genre.library.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 8))
        let populated = NSPredicate(format: "value != '0 items'")
        expectation(for: populated, evaluatedWith: library)
        waitForExpectations(timeout: 20)

        let posterButtons = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "media.poster.")
        )
        var focusedPoster: XCUIElement?
        for _ in 0..<8 {
            focusedPoster = posterButtons.allElementsBoundByIndex.first(where: \.hasFocus)
            if focusedPoster != nil { break }
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let focusedPoster else {
            XCTFail("Could not focus the first poster in \(selectedGenre)")
            return
        }
        let selectedPosterID = focusedPoster.identifier.replacingOccurrences(
            of: "media.poster.",
            with: ""
        )
        let selectedPosterName = focusedPoster.label
        remote.press(.select)

        let detail = app.descendants(matching: .any)["detail.item.\(selectedPosterID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 8), "Did not open \(selectedPosterName)")
        // Detail could flash and pop back to the genre; wait to prove it stays.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(detail.exists, "Detail popped behind the genre library")

        remote.press(.menu)
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertFalse(detail.exists, "Back left the item detail above the genre library")

        remote.press(.menu)
        XCTAssertTrue(
            app.descendants(matching: .any)["home.genres.movies"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)["home.genres.shows"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(library.exists, "Second Back did not return from genre to Home")

        // Back restores focus to the exact genre card.
        XCTAssertTrue(selectedGenreButton.hasFocus)
        remote.press(.select)
        XCTAssertTrue(library.waitForExistence(timeout: 8))

        // The demo catalogue changes; only assert scrolling when there are enough rows.
        if posterButtons.count > 8 {
            for _ in 0..<6 {
                remote.press(.down)
                Thread.sleep(forTimeInterval: 0.15)
            }
            XCTAssertFalse(
                title.frame.intersects(app.frame),
                "The genre heading should scroll away instead of covering the poster grid"
            )
        }
    }

    /// Seeds the search query, since typing on the tvOS keyboard is one
    /// glyph at a time.
    private func launchSeededSearchApp(query: String) -> XCUIApplication {
        let app = XCUIApplication.regression(extra: ["-debug.searchRegressionQuery", query])
        app.launch()
        return app
    }

    private func launchNavigationRegressionApp() -> XCUIApplication {
        let app = XCUIApplication.regression(extra: ["-debug.navigationRegression", "YES"])
        app.launch()
        return app
    }
}

#endif

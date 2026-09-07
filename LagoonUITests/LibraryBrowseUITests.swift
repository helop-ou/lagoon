import XCTest

final class LibraryBrowseUITests: XCTestCase {
    private let remote = XCUIRemote.shared

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDecadeFiltersCombinePersistAndClear() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.navigationRegression", "YES",
        ]
        app.launch()
        openLibrary(app)
        chooseKind(app, title: "Shows")
        focusFilters(app)
        let summary = app.staticTexts["library.filters.summary"]
        let filters = app.descendants(matching: .any)["library.filters"]
        if summary.exists { chooseFilter(app, title: "Clear Filters") }
        XCTAssertTrue(app.staticTexts["library.count"].waitForExistence(timeout: 35), "The demo catalogue must finish loading before testing its genre filters")

        chooseFilter(app, title: "2000–2009", submenu: "Decade")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2000–2009"))
        XCTAssertEqual(filters.value as? String, "1 active")
        chooseFilter(app, title: "Drama", submenu: "Genre")
        chooseFilter(app, title: "Unwatched Only")
        XCTAssertTrue(summary.label.contains("2000–2009"))
        XCTAssertTrue(summary.label.contains("Drama"))
        XCTAssertTrue(summary.label.contains("Unwatched"))
        XCTAssertEqual(filters.value as? String, "3 active")
        capture(app, name: "Decade With Genre And Unwatched")

        app.terminate()
        app.launch()
        openLibrary(app)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("2000–2009"))
        XCTAssertTrue(summary.label.contains("Drama"))
        XCTAssertTrue(summary.label.contains("Unwatched"))
        XCTAssertEqual(filters.value as? String, "3 active")

        focusFilters(app)
        chooseFilter(app, title: "All Decades", submenu: "Decade")
        XCTAssertFalse(summary.label.contains("2000–2009"))
        XCTAssertTrue(summary.label.contains("Drama"))
        XCTAssertTrue(summary.label.contains("Unwatched"))
        XCTAssertEqual(filters.value as? String, "2 active")
        chooseFilter(app, title: "2010–2019", submenu: "Decade")
        XCTAssertTrue(summary.label.contains("2010–2019"))
        chooseFilter(app, title: "Clear Filters")
        XCTAssertTrue(summary.waitForNonExistence(timeout: 5))
        XCTAssertEqual(filters.value as? String, "0 active")
    }

    func testLibraryFiltersSortingAndReturnNavigation() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-debug.playerRegression", "YES",
            "-debug.regressionBootstrapPublicDemo", "YES",
            "-debug.navigationRegression", "YES",
        ]
        app.launch()
        openLibrary(app)
        XCTAssertFalse(app.tabBars.buttons["Movies"].exists)
        XCTAssertFalse(app.tabBars.buttons["Shows"].exists)

        let posters = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "media.poster."))
        XCTAssertTrue(posters.firstMatch.waitForExistence(timeout: 20))
        capture(app, name: "Unified Library")

        let picker = app.descendants(matching: .any)["library.kind"]
        XCTAssertTrue(picker.exists, app.debugDescription)
        XCTAssertFalse(app.segmentedControls["library.kind"].exists)
        chooseKind(app, title: "Movies")
        focusFilters(app)
        let summary = app.staticTexts["library.filters.summary"]
        if summary.exists { chooseFilter(app, title: "Clear Filters") }
        move(to: picker, direction: .left)
        capture(app, name: "Native Media Type Picker Focused")

        // Merely exploring another menu option, then pressing Back, must
        // leave Movies selected. A native menu picker commits on Select.
        remote.press(.select)
        let shows = menuCell(app, title: "Shows")
        XCTAssertTrue(shows.waitForExistence(timeout: 5))
        move(to: shows, direction: .down)
        capture(app, name: "Media Type Menu Before Selection")
        remote.press(.menu)
        XCTAssertTrue(shows.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Movies")

        let sort = app.descendants(matching: .any)["library.sort"]
        move(to: sort, direction: .right)
        XCTAssertEqual(picker.value as? String, "Movies", "Moving to Sort must not change the media type")
        remote.press(.select)
        let recentlyAdded = menuCell(app, title: "Recently Added")
        XCTAssertTrue(recentlyAdded.waitForExistence(timeout: 5))
        move(to: recentlyAdded, direction: .down)
        remote.press(.select)
        XCTAssertTrue(recentlyAdded.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(sort.value as? String, "Recently Added")

        let filters = app.descendants(matching: .any)["library.filters"]
        XCTAssertTrue(filters.exists)
        move(to: filters, direction: .right)
        XCTAssertEqual(picker.value as? String, "Movies", "Moving to Filters must not change the media type")
        remote.press(.select)
        let unwatched = menuCell(app, title: "Unwatched Only")
        XCTAssertTrue(unwatched.waitForExistence(timeout: 5))
        // The demo has one Movies library: the media-type control already
        // makes that choice, so neither the old Source nor Library is useful.
        XCTAssertFalse(menuCell(app, title: "Source").exists)
        XCTAssertFalse(menuCell(app, title: "Library").exists)
        XCTAssertTrue(menuCell(app, title: "4K Only").exists)
        capture(app, name: "Movie Filters")
        move(to: unwatched, direction: .down)
        remote.press(.select)
        XCTAssertTrue(unwatched.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Unwatched"))
        capture(app, name: "Filtered Movies")

        chooseFilter(app, title: "4K Only")
        XCTAssertTrue(summary.label.contains("4K"))
        move(to: picker, direction: .left)
        move(to: filters, direction: .right)
        XCTAssertEqual(picker.value as? String, "Movies")
        XCTAssertTrue(summary.label.contains("4K"), "Crossing the controls must preserve the movie-only filter")
        XCTAssertEqual(filters.value as? String, "2 active")

        // Clearing returns the complete collection without resetting sort.
        remote.press(.select)
        let clear = menuCell(app, title: "Clear Filters")
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        move(to: clear, direction: .down)
        remote.press(.select)
        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(summary.exists)
        XCTAssertEqual(sort.value as? String, "Recently Added")

        move(to: picker, direction: .left)
        XCTAssertEqual(picker.value as? String, "Movies")
        for _ in 0..<8 where !posters.allElementsBoundByIndex.contains(where: \.hasFocus) {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
        guard let poster = posters.allElementsBoundByIndex.first(where: \.hasFocus) else {
            XCTFail("Library posters could not receive focus")
            return
        }
        XCTAssertEqual(picker.value as? String, "Movies", "Selection remains visible after focus leaves the picker")
        capture(app, name: "Native Picker Unfocused")
        let itemID = poster.identifier.replacingOccurrences(of: "media.poster.", with: "")
        remote.press(.select)
        let detail = app.descendants(matching: .any)["detail.item.\(itemID)"]
        XCTAssertTrue(detail.waitForExistence(timeout: 10))
        remote.press(.menu)
        XCTAssertTrue(app.descendants(matching: .any)["library.view"].waitForExistence(timeout: 5))
        XCTAssertTrue(poster.hasFocus)

        for _ in 0..<5 { remote.press(.down) }
        capture(app, name: "Library Scrolled")
        let tab = app.tabBars.buttons["Library"]
        move(to: tab, direction: .up, limit: 30)
        XCTAssertTrue(tab.hasFocus)
        XCTAssertEqual(picker.value as? String, "Movies", "Returning to the tab bar must not change the media type")

        app.terminate()
        app.launch()
        openLibrary(app)
        XCTAssertEqual(app.descendants(matching: .any)["library.sort"].value as? String, "Recently Added")
        XCTAssertEqual(picker.value as? String, "Movies")
        capture(app, name: "Library Restored")
    }

    private func openLibrary(_ app: XCUIApplication) {
        let home = app.tabBars.buttons["Home"]
        XCTAssertTrue(home.waitForExistence(timeout: 25))
        move(to: home, direction: .up)
        let library = app.tabBars.buttons["Library"]
        move(to: library, direction: .right)
        remote.press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["library.view"].waitForExistence(timeout: 10))
    }

    private func focusFilters(_ app: XCUIApplication) {
        focusControls(app)
        move(to: app.descendants(matching: .any)["library.filters"], direction: .right)
    }

    private func focusControls(_ app: XCUIApplication) {
        let picker = app.descendants(matching: .any)["library.kind"]
        let sort = app.descendants(matching: .any)["library.sort"]
        let filters = app.descendants(matching: .any)["library.filters"]
        for _ in 0..<5 where ![picker, sort, filters].contains(where: ownsFocus) {
            remote.press(.down)
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func chooseKind(_ app: XCUIApplication, title: String) {
        focusControls(app)
        let picker = app.descendants(matching: .any)["library.kind"]
        move(to: picker, direction: .left)
        remote.press(.select)
        let all = menuCell(app, title: "All")
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        move(to: all, direction: .up)
        let option = menuCell(app, title: title)
        move(to: option, direction: .down)
        remote.press(.select)
        XCTAssertTrue(option.waitForNonExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, title)
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func chooseFilter(_ app: XCUIApplication, title: String, submenu: String? = nil) {
        remote.press(.select)
        if let submenu {
            let parent = menuCell(app, title: submenu)
            XCTAssertTrue(parent.waitForExistence(timeout: 5))
            move(to: parent, direction: .down)
            remote.press(.select)
        }
        let option = menuCell(app, title: title)
        let direction: XCUIRemote.Button = title == "All Decades" ? .up : .down
        if !option.waitForExistence(timeout: 2) {
            // Native submenus only expose rows near the visible viewport.
            for _ in 0..<24 where !option.exists {
                remote.press(direction)
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        XCTAssertTrue(option.exists, "Missing filter option: \(title)")
        move(to: option, direction: direction, limit: 24)
        if submenu == "Decade" { capture(app, name: "Decade Menu") }
        remote.press(.select)
        XCTAssertTrue(option.waitForNonExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func move(to element: XCUIElement, direction: XCUIRemote.Button, limit: Int = 12) {
        for _ in 0..<limit where !ownsFocus(element) {
            remote.press(direction)
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertTrue(ownsFocus(element), "Could not focus \(element.identifier)")
    }

    private func ownsFocus(_ element: XCUIElement) -> Bool {
        // SwiftUI Menu puts its identifier on a wrapper and focus on an
        // inner accessibility element. Other controls own focus directly.
        element.hasFocus || element.descendants(matching: .any)
            .allElementsBoundByIndex.contains(where: \.hasFocus)
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func menuCell(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label == %@", title)).firstMatch
    }
}

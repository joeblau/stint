import XCTest

final class StandingsColumnTests: XCTestCase {
    @MainActor func testFavoriteButtonsAndMenuSwitchTheLastColumn() throws {
        let app = XCUIApplication()
        // Column choices persist in UserDefaults; launch arguments would shadow them, so the test taps its way to a known state.
        app.launchArguments += ["-hud-auto-hide", "0"]
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        #endif
        if app.buttons["Pause replay"].waitForExistence(timeout: 10) { app.buttons["Pause replay"].tap() }

        let gap = app.buttons["Gap"].firstMatch
        let interval = app.buttons["Interval"].firstMatch
        let tyres = app.buttons["Tyres"].firstMatch
        let more = app.descendants(matching: .any)["More columns"].firstMatch
        XCTAssertTrue(gap.waitForExistence(timeout: 10))
        gap.tap()
        XCTAssertTrue(gap.isSelected)
        XCTAssertEqual(more.value as? String, "Gap")
        attach(app, name: "Standings gap column")

        interval.tap()
        XCTAssertTrue(interval.isSelected)
        XCTAssertFalse(gap.isSelected)
        XCTAssertEqual(more.value as? String, "Interval")
        attach(app, name: "Standings interval column")

        tyres.tap()
        XCTAssertTrue(tyres.isSelected)
        XCTAssertEqual(more.value as? String, "Tyres")
        attach(app, name: "Standings tyres column")

        // A column chosen from the menu takes over the fourth button.
        more.tap()
        let laps = app.buttons["standings-column-row-laps"]
        XCTAssertTrue(app.buttons["standings-column-row-gap"].waitForExistence(timeout: 5))
        attach(app, name: "Standings column menu")
        // The popover's dismiss region makes XCUITest treat rows as covered, so drive it by coordinates.
        let list = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        XCTAssertTrue(laps.waitForExistence(timeout: 5))
        laps.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertFalse(tyres.isSelected)
        XCTAssertEqual(more.value as? String, "Laps")
        attach(app, name: "Standings laps column")

        // Selection survives relaunch.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(more.waitForExistence(timeout: 15))
        XCTAssertEqual(more.value as? String, "Laps")
        gap.tap()
        XCTAssertEqual(more.value as? String, "Gap")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

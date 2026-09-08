import XCTest

final class CalendarFlightTests: XCTestCase {
    /// Montreal to Monaco is about 6,500 km, so the jet is airborne for roughly seven seconds.
    @MainActor func testSelectingTheNextRoundFliesTheJetAlongTheRoute() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hud-auto-hide", "0"]
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        #endif
        let calendarTab = app.buttons["tab-calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 10))
        calendarTab.tap()
        let montreal = app.buttons["calendar-race-montreal"]
        XCTAssertTrue(montreal.waitForExistence(timeout: 10))
        montreal.tap()
        sleep(2)
        let monaco = app.buttons["calendar-race-monaco"]
        XCTAssertTrue(monaco.waitForExistence(timeout: 5))
        monaco.tap()
        let leg = app.staticTexts["calendar-flight-leg"].firstMatch.exists
            ? app.staticTexts["calendar-flight-leg"].firstMatch : app.otherElements["calendar-flight-leg"].firstMatch
        XCTAssertTrue(leg.waitForExistence(timeout: 5))
        XCTAssertTrue((leg.label.contains("km") && leg.label.contains("min")) || leg.label.contains("Flight from"))
        sleep(2)
        attach(app, name: "Jet mid-flight to Monaco")
        sleep(3)
        attach(app, name: "Jet late in flight to Monaco")
        sleep(4)
        attach(app, name: "Jet landed at Monaco")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

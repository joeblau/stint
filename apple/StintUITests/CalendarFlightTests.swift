import XCTest

private extension XCUIElement {
    func pressFlightControl() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}

final class CalendarFlightTests: XCTestCase {
    /// Montreal to Monaco is about 6,500 km, so the jet is airborne for roughly seven seconds.
    @MainActor func testSelectingTheNextRoundFliesTheJetAlongTheRoute() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hud-auto-hide", "0"]
        app.launchEnvironment["STINT_FORCE_FLIGHT"] = "1"
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        #endif
        let calendarTab = app.buttons["tab-calendar"]
        XCTAssertTrue(calendarTab.waitForExistence(timeout: 10))
        calendarTab.pressFlightControl()
        let montreal = app.buttons["calendar-race-montreal"]
        XCTAssertTrue(montreal.waitForExistence(timeout: 10))
        montreal.pressFlightControl()
        sleep(2)
        let monaco = app.buttons["calendar-race-monaco"]
        XCTAssertTrue(monaco.waitForExistence(timeout: 5))
        monaco.pressFlightControl()
        let leg = app.staticTexts["calendar-flight-leg"].firstMatch.exists
            ? app.staticTexts["calendar-flight-leg"].firstMatch : app.otherElements["calendar-flight-leg"].firstMatch
        XCTAssertTrue(leg.waitForExistence(timeout: 5))
        let legText = leg.label + " " + (leg.value as? String ?? "")
        XCTAssertTrue((legText.contains("km") && legText.contains("min")) || legText.contains("Flight from"), legText)
        let jet = app.descendants(matching: .any)["calendar-jet"].firstMatch
        XCTAssertTrue(jet.waitForExistence(timeout: 3), "The actual 3D jet must appear during the flight")
        sleep(1)
        attach(app, name: "Jet mid-flight to Monaco")
        sleep(3)
        attach(app, name: "Jet late in flight to Monaco")
        sleep(4)
        attach(app, name: "Jet landed at Monaco")
        XCTAssertFalse(jet.exists)
        app.buttons["calendar-race-barcelona"].pressFlightControl()
        XCTAssertTrue(jet.waitForExistence(timeout: 3), "Short adjacent hops must also show the jet")
        attach(app, name: "Jet on short Monaco to Barcelona hop")
    }

    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        #if os(macOS)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

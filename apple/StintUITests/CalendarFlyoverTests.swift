import XCTest

final class CalendarFlyoverTests: XCTestCase {
    /// A pin click only selects the venue; a second click on it flies over the circuit.
    @MainActor func testPinClicksSelectThenFlyOverTheCircuit() throws {
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
        press(calendarTab)
        // Establish a previous selection so a flight would otherwise be possible.
        let melbourne = app.buttons["calendar-race-melbourne"]
        XCTAssertTrue(melbourne.waitForExistence(timeout: 10))
        press(melbourne)
        sleep(2)
        press(app.buttons["entire-globe"])
        sleep(2)
        // At the overview Monaco sits in a European cluster; open it first if needed.
        let monacoPin = app.buttons["venue-monaco"]
        if !monacoPin.exists {
            let cluster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'venue-cluster-'")).firstMatch
            XCTAssertTrue(cluster.waitForExistence(timeout: 5))
            press(cluster)
        }
        XCTAssertTrue(monacoPin.waitForExistence(timeout: 10))
        let jet = app.descendants(matching: .any)["calendar-jet"].firstMatch
        // First click: select without the jet.
        tapWhenStill(monacoPin)
        sleep(2)
        XCTAssertFalse(jet.exists, "Clicking a city pin must not fly the jet")
        attach(app, name: "Pin click selects Monaco")
        // Second click on the selected pin: fly over the circuit.
        tapWhenStill(monacoPin)
        let flying = NSPredicate(format: "value BEGINSWITH 'Flying over'")
        XCTAssertTrue(app.buttons.matching(flying).firstMatch.waitForExistence(timeout: 5), "Second pin click starts the fly-over")
        sleep(3)
        attach(app, name: "Fly-over settling above Monaco")
        sleep(8)
        attach(app, name: "Fly-over chase lap at Monaco")
        sleep(19)
        attach(app, name: "Fly-over pulled back over Monaco")
        XCTAssertFalse(app.buttons.matching(flying).firstMatch.exists, "The pass ends on its own")
    }

    /// Camera moves animate for a few seconds; tap only once the pin stops moving.
    @MainActor private func tapWhenStill(_ element: XCUIElement) {
        var frame = element.frame
        for _ in 0..<20 {
            usleep(500_000)
            let next = element.frame
            if abs(next.midX - frame.midX) < 1 && abs(next.midY - frame.midY) < 1 { break }
            frame = next
        }
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
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

import XCTest

#if os(macOS)
final class TempPlaneShots: XCTestCase {
    @MainActor func testPlaneFlightBetweenRaces() {
        let app = XCUIApplication()
        app.launchEnvironment["STINT_FORCE_FLIGHT"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["tab-calendar"].waitForExistence(timeout: 20))
        app.buttons["tab-calendar"].click()
        XCTAssertTrue(app.buttons["calendar-race-monaco"].waitForExistence(timeout: 10))
        app.buttons["calendar-race-monaco"].click()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(app.buttons["calendar-race-melbourne"].waitForExistence(timeout: 5))
        app.buttons["calendar-race-melbourne"].click()
        for (index, delay) in [1.5, 2.0, 2.5].enumerated() {
            Thread.sleep(forTimeInterval: delay)
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "plane flight \(index)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTFail("Intentional: keep the flight recording.")
    }
}

#endif

import XCTest

final class MiamiSurfaceUITests: XCTestCase {
    #if os(macOS)
    @MainActor func testMiamiContinuousSurfaceInLowFlyover() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-hud-auto-hide", "0", "-onboarding-completed", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-calendar"].waitForExistence(timeout: 15))
        app.buttons["tab-calendar"].click()
        let miami = app.buttons["calendar-race-miami"]
        XCTAssertTrue(miami.waitForExistence(timeout: 10))
        miami.click()
        let flyover = app.buttons["flyover-circuit"]
        XCTAssertTrue(flyover.waitForExistence(timeout: 10))
        flyover.click()
        sleep(10)
        flyover.click() // Pause before inspecting repeatable locations along the lap.
        let scrub = app.sliders["flyover-scrub"]
        XCTAssertTrue(scrub.exists)
        for (position, label) in [(0.83, "Miami continuous north straight"), (0.94, "Miami red white corner kerbs")] {
            scrub.coordinate(withNormalizedOffset: CGVector(dx: position, dy: 0.5)).click()
            sleep(5)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }
    #endif
}

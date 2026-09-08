import XCTest

final class TempPanShots: XCTestCase {
    @MainActor func testCarsStayGluedDuringPan() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.buttons["Pause replay"].waitForExistence(timeout: 20))
        app.buttons["Pause replay"].click()
        let window = app.windows.firstMatch
        let center = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<3 {
            center.click(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.4)))
            center.click(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.6)))
        }
        XCTFail("Intentional: keep the screen recording of the pans.")
    }
}

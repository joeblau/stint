import XCTest

private extension XCUIElement {
    func press() {
        #if os(macOS)
        click()
        #else
        tap()
        #endif
    }
}

final class MapFlowTests: XCTestCase {
    #if os(iOS)
    @MainActor func testPinchReleasesFollowCamera() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hud-auto-hide", "YES"]
        app.launch()
        revealControls(app)
        app.buttons["Follow car"].press()
        XCTAssertTrue(app.buttons["Zoom out"].waitForExistence(timeout: 10))
        // XCTest starts its pinch near opposite corners. Hide the HUD first so
        // both fingers land on the map, rather than on the standings and player.
        let clearMap = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.buttons["Zoom out"])
        await fulfillment(of: [clearMap], timeout: 15)
        app.otherElements["race-map"].pinch(withScale: 0.5, velocity: -1)
        let released = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["Follow car"])
        await fulfillment(of: [released], timeout: 10)
        let zoomedOut = XCTAttachment(screenshot: screenshot(app))
        zoomedOut.name = "Pinch out of follow camera"
        zoomedOut.lifetime = .keepAlways
        add(zoomedOut)
        let clearAgain = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.buttons["Follow car"])
        await fulfillment(of: [clearAgain], timeout: 15)
        app.otherElements["race-map"].pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(app.buttons["Follow car"].isHittable)
    }
    #endif

    @MainActor func testSelectedGlobePinZoomsIntoCircuit() async throws {
        let app = XCUIApplication()
        app.launchArguments = ["-hud-auto-hide", "NO"]
        app.launch()
        revealControls(app)
        app.buttons["tab-calendar"].press()
        let race = app.buttons["calendar-race-melbourne"]
        let schedule = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: race)
        await fulfillment(of: [schedule], timeout: 15)
        race.press()
        let pin = app.buttons["venue-melbourne"]
        let visible = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: pin)
        await fulfillment(of: [visible], timeout: 15)
        // The race is already selected; clicking its pin must still zoom closer.
        pin.press()
        let close = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: pin)
        await fulfillment(of: [close], timeout: 15)
        XCTAssertTrue(app.buttons["open-calendar-race"].exists)
        #if os(iOS)
        app.descendants(matching: .any)["calendar-month-grid"].swipeLeft()
        XCTAssertEqual(app.staticTexts["calendar-month"].label, "April")
        app.descendants(matching: .any)["calendar-month-grid"].swipeRight()
        XCTAssertEqual(app.staticTexts["calendar-month"].label, "March")
        #endif
        let circuit = XCTAttachment(screenshot: screenshot(app))
        circuit.name = "Selected globe pin zoomed into circuit"
        circuit.lifetime = .keepAlways
        add(circuit)
    }

    @MainActor func testFloatingTabsAndAutoHideToggle() async throws {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        let toggle = app.buttons["hud-auto-hide"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.value as? String == "On" { toggle.press() }
        XCTAssertEqual(toggle.value as? String, "Off")
        try await Task.sleep(for: .seconds(6))
        XCTAssertTrue(app.buttons["tab-calendar"].isHittable)
        XCTAssertTrue(app.buttons["Map appearance"].isHittable)
        XCTAssertTrue(app.buttons["telemetry-speed-unit"].isHittable)
        let controls = XCTAttachment(screenshot: screenshot(app))
        controls.name = "Floating tabs and native map controls"
        controls.lifetime = .keepAlways
        add(controls)
        app.buttons["tab-calendar"].press()
        let calendar = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["entire-globe"])
        await fulfillment(of: [calendar], timeout: 10)
        XCTAssertTrue(app.buttons["tab-race"].isHittable)
        let season = XCTAttachment(screenshot: screenshot(app))
        season.name = "Season calendar appearance"
        season.lifetime = .keepAlways
        add(season)
        app.buttons["tab-race"].press()
        let race = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: toggle)
        await fulfillment(of: [race], timeout: 10)
        XCTAssertEqual(toggle.value as? String, "Off")
        app.activate()
        app.buttons["hud-auto-hide"].press()
        XCTAssertEqual(app.buttons["hud-auto-hide"].value as? String, "On")
        let hidden = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.buttons["Map appearance"])
        await fulfillment(of: [hidden], timeout: 15)
        let tabsHidden = expectation(for: NSPredicate(format: "isHittable == false"), evaluatedWith: app.buttons["tab-calendar"])
        await fulfillment(of: [tabsHidden], timeout: 5)
        revealControls(app)
        let restored = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["tab-calendar"])
        await fulfillment(of: [restored], timeout: 5)
    }

    @MainActor func testGaugeSpeedUnits() {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        if app.buttons["Pause replay"].exists { app.buttons["Pause replay"].press() }
        XCTAssertTrue(app.buttons["Play replay"].exists)
        revealControls(app)
        let speed = app.buttons["telemetry-speed-unit"]
        XCTAssertTrue(speed.waitForExistence(timeout: 5))
        let original = speed.value as? String ?? ""
        speed.press()
        let changed = speed.value as? String ?? ""
        XCTAssertNotEqual(changed, original)
        XCTAssertTrue(changed.contains(original.contains("kilometers") ? "miles per hour" : "kilometers per hour"))
        let converted = XCTAttachment(screenshot: screenshot(app))
        converted.name = "Gauge converted speed units"
        converted.lifetime = .keepAlways
        add(converted)
        revealControls(app)
        speed.press()
        XCTAssertEqual(speed.value as? String, original)
        let restored = XCTAttachment(screenshot: screenshot(app))
        restored.name = "Gauge original speed units"
        restored.lifetime = .keepAlways
        add(restored)
    }

    @MainActor func testLightingAndFollowTransitions() async throws {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        app.buttons["Pause replay"].press()
        app.buttons["Map lighting"].press()
        app.buttons["lighting-Day"].press()
        XCTAssertEqual(app.buttons["Map lighting"].value as? String, "Day")
        try await Task.sleep(for: .seconds(1))
        let day = XCTAttachment(screenshot: screenshot(app))
        day.name = "Stint day lighting"
        day.lifetime = .keepAlways
        add(day)
        app.buttons["lighting-Night"].press()
        XCTAssertEqual(app.buttons["Map lighting"].value as? String, "Night")
        try await Task.sleep(for: .seconds(1))
        let night = XCTAttachment(screenshot: screenshot(app))
        night.name = "Stint night lighting"
        night.lifetime = .keepAlways
        add(night)
        app.buttons["lighting-Race time"].press()
        XCTAssertEqual(app.buttons["Map lighting"].value as? String, "Race time")
        XCTAssertTrue(app.staticTexts["Race time · 15:00 local"].exists)
        revealControls(app)
        app.buttons["Follow car"].press()
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.buttons["Zoom out"].exists)
        let follow = XCTAttachment(screenshot: screenshot(app))
        follow.name = "Stint paused follow after camera flight"
        follow.lifetime = .keepAlways
        add(follow)
        app.buttons["Zoom out"].press()
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.buttons["Follow car"].exists)
        let overview = XCTAttachment(screenshot: screenshot(app))
        overview.name = "Stint overview after return flight"
        overview.lifetime = .keepAlways
        add(overview)
    }

    @MainActor func testCalendarGlobeAndOpeningRace() {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        app.buttons["tab-calendar"].press()
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["calendar-race-melbourne"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.otherElements["season-schedule"].waitForExistence(timeout: 5))
        let globe = XCTAttachment(screenshot: screenshot(app))
        globe.name = "2026 season globe"
        globe.lifetime = .keepAlways
        add(globe)
        app.buttons["calendar-race-melbourne"].press()
        XCTAssertTrue(app.buttons["calendar-day-3-8"].waitForExistence(timeout: 5))
        app.buttons["calendar-day-3-15"].press()
        XCTAssertTrue(app.staticTexts["Shanghai International Circuit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["venue-shanghai"].waitForExistence(timeout: 5))
        app.buttons["venue-shanghai"].press()
        let selection = XCTAttachment(screenshot: screenshot(app))
        selection.name = "Calendar date and track selection"
        selection.lifetime = .keepAlways
        add(selection)
        app.buttons["open-calendar-race"].press()
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["Pause replay"])
        waitForExpectations(timeout: 10)
        XCTAssertTrue(app.otherElements["telemetry-gauge"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["STANDINGS"].exists)
        app.buttons["tab-calendar"].press()
        expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: app.buttons["entire-globe"])
        waitForExpectations(timeout: 10)
        app.buttons["entire-globe"].press()
        XCTAssertFalse(app.buttons["open-calendar-race"].exists)
    }

    @MainActor private func revealControls(_ app: XCUIApplication) {
        #if os(macOS)
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        #endif
    }

    @MainActor private func screenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        #if os(macOS)
        return app.windows.firstMatch.screenshot()
        #else
        return app.screenshot()
        #endif
    }

    @MainActor func testReplayAndTrackSelection() throws {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        XCTAssertTrue(app.buttons["Pause replay"].waitForExistence(timeout: 20))
        app.buttons["Pause replay"].press()
        XCTAssertTrue(app.buttons["Play replay"].exists)
        XCTAssertTrue(app.staticTexts["STANDINGS"].exists)

        let overview = XCTAttachment(screenshot: screenshot(app))
        overview.name = "Monaco overview"
        overview.lifetime = .keepAlways
        add(overview)

        app.buttons["tab-calendar"].press()
        XCTAssertTrue(app.buttons["calendar-race-monza"].waitForExistence(timeout: 10))
        app.buttons["calendar-race-monza"].press()
        XCTAssertTrue(app.buttons["open-calendar-race"].waitForExistence(timeout: 5))
        app.buttons["open-calendar-race"].press()
        XCTAssertTrue(app.buttons["Pause replay"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.otherElements["telemetry-gauge"].waitForExistence(timeout: 5))
        app.buttons["Pause replay"].press()
        app.buttons["Follow car"].press()
        XCTAssertTrue(app.buttons["Zoom out"].exists)
        let follow = XCTAttachment(screenshot: screenshot(app))
        follow.name = "3D car follow"
        follow.lifetime = .keepAlways
        add(follow)
        app.buttons["Zoom out"].press()
        XCTAssertTrue(app.buttons["Follow car"].exists)

        app.buttons["driver-LEC"].press()
        XCTAssertTrue(app.staticTexts["Charles Leclerc"].exists)
        app.buttons["Map appearance"].press()
        XCTAssertTrue(app.staticTexts["Car size"].waitForExistence(timeout: 5))
    }

    @MainActor func testControlsFadeAndReturnOnMapInteraction() {
        let app = XCUIApplication()
        app.launch()
        revealControls(app)
        XCTAssertTrue(app.buttons["Pause replay"].waitForExistence(timeout: 20))
        app.buttons["Pause replay"].press()
        let hidden = NSPredicate(format: "isHittable == false")
        expectation(for: hidden, evaluatedWith: app.buttons["Follow car"])
        // Simulator accessibility snapshots can take several seconds with the full field.
        waitForExpectations(timeout: 15)
        XCTAssertFalse(app.buttons["tab-calendar"].isHittable)

        let clean = XCTAttachment(screenshot: screenshot(app))
        clean.name = "Map after five seconds"
        clean.lifetime = .keepAlways
        add(clean)
        revealControls(app)
        XCTAssertTrue(app.buttons["Follow car"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Follow car"].isHittable)
        XCTAssertTrue(app.buttons["tab-calendar"].isHittable)
    }
}

import XCTest
@testable import Stint

final class OverlayVisibilityTests: XCTestCase {
    @MainActor func testTurningOffAutoHideRevealsAndKeepsHUDVisible() {
        let overlays = OverlayVisibility(now: 0)
        overlays.update(at: 5, isInteracting: false)
        XCTAssertFalse(overlays.isVisible)
        overlays.update(at: 10, isInteracting: false, autoHideEnabled: false)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 100, isInteracting: false, autoHideEnabled: false)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 104.9, isInteracting: false, autoHideEnabled: true)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 105, isInteracting: false, autoHideEnabled: true)
        XCTAssertFalse(overlays.isVisible)
    }

    @MainActor func testHidesAfterFiveSecondsAndInteractionRestartsCountdown() {
        let overlays = OverlayVisibility(now: 0)
        overlays.update(at: 4.9, isInteracting: false)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 5, isInteracting: false)
        XCTAssertFalse(overlays.isVisible)
        overlays.reveal(at: 8)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 12.9, isInteracting: false)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 13, isInteracting: false)
        XCTAssertFalse(overlays.isVisible)
    }

    @MainActor func testPopoverAndScrubbingHoldControlsOpen() {
        let overlays = OverlayVisibility(now: 0)
        overlays.update(at: 10, isInteracting: true)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 14.9, isInteracting: false)
        XCTAssertTrue(overlays.isVisible)
        overlays.update(at: 15, isInteracting: false)
        XCTAssertFalse(overlays.isVisible)
    }
}

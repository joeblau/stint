import XCTest
@testable import Stint

final class GlobeFlyoverTests: XCTestCase {
    private func surface() -> SeasonGlobeSurface {
        let surface = SeasonGlobeSurface(onSelect: { _ in })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        return surface
    }

    @MainActor func testPinClickSelectsWithoutTheJetAndSecondClickStartsTheFlyover() throws {
        let surface = surface()
        let melbourne = try XCTUnwrap(Season2026.races.first { $0.circuitID == "melbourne" })
        let monaco = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        surface.update(selected: melbourne.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, flyover: UUID(), onComplete: {})
        surface.selectVenue(monaco)
        XCTAssertNil(surface.planeFlight, "A pin click selects the venue without flying the jet")
        XCTAssertFalse(surface.isFlyingOver)
        surface.selectVenue(monaco)
        XCTAssertTrue(surface.isFlyingOver, "A second click on the selected pin starts the track fly-over")
        XCTAssertNil(surface.planeFlight)
        // Frames drive the camera down onto the circuit and back out again.
        let began = ProcessInfo.processInfo.systemUptime
        surface.displayFrame(at: began + TrackFlyover.settleDuration + TrackFlyover.lapDuration / 2)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, TrackFlyover.chaseDistance, accuracy: 5)
        XCTAssertEqual(surface.map.camera.pitch, TrackFlyover.chasePitch, accuracy: 1)
        surface.displayFrame(at: began + 60)
        XCTAssertFalse(surface.isFlyingOver, "The pass ends after its duration")
        XCTAssertEqual(surface.map.camera.pitch, TrackFlyover.finalPitch, accuracy: 1)
        // Selecting somewhere else ends the pass.
        surface.update(selected: melbourne.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, flyover: UUID(), onComplete: {})
        XCTAssertFalse(surface.isFlyingOver)
    }

    @MainActor func testFlyoverRequestFromTheCardStartsThePass() throws {
        let surface = surface()
        let monaco = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        let request = UUID()
        let overview = UUID()
        surface.update(selected: monaco.id, overview: overview, now: Date(), active: true,
                       flight: nil, reduceMotion: false, flyover: request, onComplete: {})
        XCTAssertFalse(surface.isFlyingOver, "The initial request token must not start a pass")
        surface.update(selected: monaco.id, overview: overview, now: Date(), active: true,
                       flight: nil, reduceMotion: false, flyover: UUID(), onComplete: {})
        XCTAssertTrue(surface.isFlyingOver)
        // "Entire globe" ends the pass.
        surface.update(selected: nil, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, flyover: UUID(), onComplete: {})
        XCTAssertFalse(surface.isFlyingOver)
    }
}

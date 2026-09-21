import XCTest
import MapKit
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
        let pass = TrackFlyover(circuit: try monaco.circuit.loadCircuit())
        let began = ProcessInfo.processInfo.systemUptime
        surface.displayFrame(at: began + TrackFlyover.settleDuration + pass.lapDuration / 2)
        XCTAssertLessThan(surface.map.camera.centerCoordinateDistance, 110,
                          "The flyover must use the closer location-supported camera range")
        XCTAssertEqual(surface.map.camera.pitch, 55, accuracy: 1,
                       "The close camera should look down at the track instead of toward the horizon")
        surface.displayFrame(at: began + pass.duration + 1)
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
    @MainActor func testManualCameraMovementReleasesFlyoverWithoutSnappingBack() throws {
        let surface = surface()
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "miami" })
        surface.update(selected: race.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        surface.startFlyover(race)
        let now = ProcessInfo.processInfo.systemUptime
        surface.displayFrame(at: now + 10)
        XCTAssertTrue(surface.isFlyingOver)
        XCTAssertTrue(surface.map.isRotateEnabled)
        XCTAssertTrue(surface.map.isPitchEnabled)
        let camera = surface.map.camera.copy() as! MKMapCamera
        surface.beginManualCameraMovement()
        XCTAssertFalse(surface.isFlyingOver)
        XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, camera.centerCoordinate.latitude, accuracy: 0.000001)
        camera.heading += 25
        camera.centerCoordinate.latitude += 0.0005
        surface.map.setCamera(camera, animated: false)
        let manual = surface.map.camera.copy() as! MKMapCamera
        surface.displayFrame(at: now + 20)
        XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, manual.centerCoordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(surface.map.camera.heading, manual.heading, accuracy: 0.001)
    }

}

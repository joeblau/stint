import XCTest
import MapKit
@testable import Stint

final class FollowCameraTests: XCTestCase {
    @MainActor func testTiltAnimatesWhilePausedAndCanReverseWithoutJumping() {
        for followsDriver in [false, true] {
            let session = RaceSession()
            session.isPlaying = false
            if followsDriver { session.toggleFollow() }
            let surface = RaceMapSurface(session: session)
            surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
            surface.layout()
            let initialPitch = surface.map.camera.pitch
            XCTAssertGreaterThan(initialPitch, 0) // MapKit may clamp the requested pitch.

            session.tilted = false
            surface.update(session: session, now: 100)
            XCTAssertEqual(surface.map.camera.pitch, initialPitch, accuracy: 0.5)
            surface.advanceCameraTransition(at: 100.9)
            XCTAssertGreaterThan(surface.map.camera.pitch, 0)
            XCTAssertLessThan(surface.map.camera.pitch, initialPitch)
            surface.advanceCameraTransition(at: 102)
            XCTAssertEqual(surface.map.camera.pitch, 0, accuracy: 0.5)

            session.tilted = true
            surface.update(session: session, now: 103)
            XCTAssertEqual(surface.map.camera.pitch, 0, accuracy: 0.5)
            surface.advanceCameraTransition(at: 103.9)
            let halfway = surface.map.camera.pitch
            XCTAssertGreaterThan(halfway, 0)
            XCTAssertLessThan(halfway, initialPitch)
            session.tilted = false
            surface.update(session: session, now: 104)
            XCTAssertEqual(surface.map.camera.pitch, halfway, accuracy: 0.5)
            surface.advanceCameraTransition(at: 106)
            XCTAssertEqual(surface.map.camera.pitch, 0, accuracy: 0.5)

            surface.reduceMotion = true
            session.tilted = true
            surface.update(session: session, now: 107)
            XCTAssertGreaterThan(surface.map.camera.pitch, 0)
            XCTAssertEqual(session.followsDriver, followsDriver)
        }
    }

    @MainActor func testPausedFollowAndOverviewAnimateWithoutJumping() throws {
        let session = RaceSession()
        session.isPlaying = false
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let overviewDistance = surface.map.camera.centerCoordinateDistance

        session.toggleFollow()
        surface.update(session: session, now: 100)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, overviewDistance, accuracy: 1)
        surface.advanceCameraTransition(at: 100.9)
        let halfway = surface.map.camera.centerCoordinateDistance
        XCTAssertLessThan(halfway, overviewDistance)
        XCTAssertGreaterThan(halfway, 150)
        surface.advanceCameraTransition(at: 102)
        let closeDistance = surface.map.camera.centerCoordinateDistance
        XCTAssertLessThan(closeDistance, 150)
        XCTAssertGreaterThan(surface.map.camera.pitch, 60)
        let car = try XCTUnwrap(session.selectedPosition)
        XCTAssertTrue(surface.bounds.contains(surface.map.convert(car.point.coordinate, toPointTo: surface)))

        session.overview()
        surface.update(session: session, now: 103)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, closeDistance, accuracy: 1)
        surface.advanceCameraTransition(at: 103.9)
        let returning = surface.map.camera.centerCoordinateDistance
        XCTAssertGreaterThan(returning, closeDistance)
        XCTAssertLessThan(returning, overviewDistance)

        session.toggleFollow()
        surface.update(session: session, now: 104)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, returning, accuracy: 1)
        surface.advanceCameraTransition(at: 106)
        XCTAssertLessThan(surface.map.camera.centerCoordinateDistance, 150)
        session.overview()
        surface.update(session: session, now: 107)
        surface.advanceCameraTransition(at: 109)
        XCTAssertGreaterThan(surface.map.camera.centerCoordinateDistance, 150)
        for point in try XCTUnwrap(session.replay).circuit {
            XCTAssertTrue(surface.bounds.contains(surface.map.convert(point.coordinate, toPointTo: surface)),
                          "Zooming out must fit the whole circuit.")
        }
    }

    @MainActor func testSwitchingFollowedDriversAnimatesOnDisplayClockWhilePaused() throws {
        let session = RaceSession()
        session.isPlaying = false
        session.toggleFollow()
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        surface.displayFrame(at: 100)
        let first = try XCTUnwrap(session.selectedDriverID)
        let second = try XCTUnwrap(session.standings.first { $0.id != first })
        let start = surface.map.camera.centerCoordinate
        session.selectedDriverID = second.id
        surface.requestUpdate()
        surface.displayFrame(at: 101)
        XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, start.latitude, accuracy: 0.00001)
        surface.displayFrame(at: 101.9)
        let halfway = surface.map.camera.centerCoordinate
        XCTAssertGreaterThan(abs(halfway.latitude - start.latitude) + abs(halfway.longitude - start.longitude), 0.000001)
        XCTAssertTrue(surface.isRenderingContinuously)
        surface.displayFrame(at: 103)
        let destination = surface.map.camera.centerCoordinate
        XCTAssertEqual(destination.latitude, second.point.latitude, accuracy: 0.00001)
        XCTAssertEqual(destination.longitude, second.point.longitude, accuracy: 0.00001)
        XCTAssertFalse(surface.isRenderingContinuously)
        XCTAssertEqual(session.time, 0)
        XCTAssertEqual(session.renderTime, 0)
        XCTAssertFalse(session.isPlaying)
        surface.setActive(false)
    }

    @MainActor func testReduceMotionSkipsFollowTransition() {
        let session = RaceSession()
        session.isPlaying = false
        let surface = RaceMapSurface(session: session)
        surface.reduceMotion = true
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        session.toggleFollow()
        surface.update(session: session)
        XCTAssertLessThan(surface.map.camera.centerCoordinateDistance, 150)
        session.overview()
        surface.update(session: session)
        XCTAssertGreaterThan(surface.map.camera.centerCoordinateDistance, 150)
    }

    @MainActor func testPausedCloseFollowKeepsCarInViewAtLowAngle() throws {
        let session = RaceSession()
        session.isPlaying = false
        session.toggleFollow()
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        surface.update(session: session)

        let car = try XCTUnwrap(session.selectedPosition)
        let point = surface.map.convert(car.point.coordinate, toPointTo: surface)
        XCTAssertTrue(surface.bounds.contains(point), "The followed car must remain visible after MapKit clamps the camera.")
        XCTAssertGreaterThan(surface.map.camera.pitch, 60)
        XCTAssertLessThan(surface.map.camera.centerCoordinateDistance, 150)
    }

    func testFollowTurnsThroughNorthAlongShortestArc() {
        var camera = FollowCamera()
        _ = camera.update(target: 350, elapsed: 0)
        let heading = camera.update(target: 10, elapsed: 0.1)
        XCTAssertTrue(heading > 350 || heading < 10)
        XCTAssertEqual(camera.update(target: 10, elapsed: 5), 10, accuracy: 0.001)
    }

    func testSmoothingDoesNotDependOnFrameRate() {
        var slow = FollowCamera()
        var fast = FollowCamera()
        _ = slow.update(target: 0, elapsed: 0)
        _ = fast.update(target: 0, elapsed: 0)
        for _ in 0..<30 { _ = slow.update(target: 90, elapsed: 1.0 / 30) }
        for _ in 0..<60 { _ = fast.update(target: 90, elapsed: 1.0 / 60) }
        XCTAssertEqual(slow.heading!, fast.heading!, accuracy: 0.0001)
    }

    func testSwitchingDriverOrSeekingCanSnapAndReleaseResetsHeading() {
        var camera = FollowCamera()
        _ = camera.update(target: 90, elapsed: 0)
        XCTAssertEqual(camera.update(target: 270, elapsed: 0.01, snap: true), 270)
        camera.reset()
        XCTAssertEqual(camera.update(target: 180, elapsed: 0), 180)
    }
}

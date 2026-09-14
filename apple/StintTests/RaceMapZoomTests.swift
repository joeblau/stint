import XCTest
import AppKit
import MapKit
@testable import Stint

final class RaceMapZoomTests: XCTestCase {
    @MainActor private func withMap(_ body: (RaceSession, RaceMapSurface) throws -> Void) rethrows {
        let session = RaceSession()
        session.isPlaying = false
        let surface = RaceMapSurface(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.layout()
        surface.update(session: session, now: 0)
        defer { surface.setActive(false); window.contentView = nil }
        try body(session, surface)
    }

    @MainActor func testMagnificationReleasesFollowWithoutChangingDisplayedCamera() {
        withMap { session, surface in
            session.followsDriver = true
            surface.update(session: session, now: 1)
            let before = surface.map.camera.copy() as! MKMapCamera
            let center = surface.map.convert(CGPoint(x: 640, y: 410), to: nil)
            surface.prepareForMapMagnification(at: center)
            XCTAssertFalse(session.followsDriver)
            XCTAssertEqual(surface.map.camera.centerCoordinateDistance, before.centerCoordinateDistance, accuracy: 0.001)
            XCTAssertEqual(surface.map.camera.heading, before.heading, accuracy: 0.001)
            XCTAssertEqual(surface.map.camera.pitch, before.pitch, accuracy: 0.001)
            // An update beyond the previous animation's end must not restore the follow camera.
            surface.update(session: session, now: 10)
            XCTAssertEqual(surface.map.camera.centerCoordinateDistance, before.centerCoordinateDistance, accuracy: 0.001)
        }
    }

    @MainActor func testBothNativeZoomDirectionsSurviveReplayUpdatesInOverview() {
        withMap { session, surface in
            session.followsDriver = false
            let center = surface.map.convert(CGPoint(x: 640, y: 410), to: nil)
            surface.prepareForMapMagnification(at: center)
            for distance in [1500.0, 4000.0, 1000.0] {
                // Native MapKit owns gesture-to-camera conversion. Check that replay updates
                // preserve its accepted camera instead of reapplying the overview/follow target.
                let camera = surface.map.camera.copy() as! MKMapCamera
                camera.pitch = 0
                camera.centerCoordinateDistance = distance
                surface.map.setCamera(camera, animated: false)
                let accepted = surface.map.camera.centerCoordinateDistance
                surface.update(session: session, now: distance)
                XCTAssertEqual(surface.map.camera.centerCoordinateDistance, accepted, accuracy: 0.001)
            }
        }
    }

    @MainActor func testHiddenRaceMapDoesNotReleaseFollowWhenCalendarIsPinched() {
        withMap { session, surface in
            session.followsDriver = true
            surface.setActive(false)
            surface.prepareForMapMagnification(at: CGPoint(x: 640, y: 410))
            XCTAssertTrue(session.followsDriver)
        }
    }

    @MainActor func testMagnificationOutsideTheMapDoesNotReleaseFollow() {
        withMap { session, surface in
            session.followsDriver = true
            surface.prepareForMapMagnification(at: CGPoint(x: -100, y: -100))
            XCTAssertTrue(session.followsDriver)
        }
    }
}

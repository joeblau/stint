import XCTest
import MapKit
@testable import Stint

final class PlaneFlightSurfaceTests: XCTestCase {
    @MainActor func testNonadjacentSelectionsGoDirectlyWithoutAJet() throws {
        let surface = SeasonGlobeSurface(onSelect: { _ in })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let monaco = Season2026.races.first { $0.circuitID == "monaco" }!
        let melbourne = Season2026.races.first { $0.circuitID == "melbourne" }!
        surface.update(selected: monaco.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        XCTAssertNil(surface.planeFlight, "First selection has no departure city")
        surface.update(selected: melbourne.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        XCTAssertNil(surface.planeFlight, "Nonadjacent selections must skip all intermediate flights")
        XCTAssertNil(surface.planePosition)
        surface.selectVenue(monaco)
        XCTAssertNil(surface.planeFlight, "Reverse nonadjacent selections also skip the jet")
        let barcelona = Season2026.races.first { $0.circuitID == "barcelona" }!
        surface.update(selected: barcelona.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        XCTAssertEqual(surface.planeFlight?.itinerary.legs.count, 1)
        surface.selectVenue(melbourne)
        XCTAssertNil(surface.planeFlight, "Skipping rounds cancels an existing flight")
        XCTAssertNil(surface.planePosition)
        surface.displayFrame(at: ProcessInfo.processInfo.systemUptime + 100)
        XCTAssertNil(surface.planePosition, "The canceled flight must not resume")
    }

    @MainActor func testFlightRespectsReduceMotion() {
        let surface = SeasonGlobeSurface(onSelect: { _ in })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let monaco = Season2026.races.first { $0.circuitID == "monaco" }!
        let barcelona = Season2026.races.first { $0.circuitID == "barcelona" }!
        surface.update(selected: monaco.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: true, onComplete: {})
        surface.update(selected: barcelona.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: true, onComplete: {})
        XCTAssertNil(surface.planeFlight, "Reduce Motion skips the flight")
    }
    @MainActor func testAdjacentScheduleSelectionKeepsCameraWithJetUntilArrival() throws {
        var selections: [Int] = []
        let surface = SeasonGlobeSurface(onSelect: { selections.append($0.id) })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let monaco = Season2026.races.first { $0.circuitID == "monaco" }!
        let barcelona = Season2026.races.first { $0.circuitID == "barcelona" }!
        let overview = UUID()
        surface.update(selected: monaco.id, overview: overview, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        surface.map.setCamera(MKMapCamera(lookingAtCenter: monaco.point.coordinate,
                                          fromDistance: 4_000_000, pitch: 0, heading: 0), animated: false)
        let start = surface.map.camera.copy() as! MKMapCamera
        surface.update(selected: barcelona.id, overview: overview, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        let flight = try XCTUnwrap(surface.planeFlight)
        XCTAssertEqual(flight.itinerary.legs.count, 1)
        XCTAssertTrue(selections.isEmpty, "Schedule selection arrives from SwiftUI, not the pin callback")
        // A repeated update with the same selection must not restart the flight or jump to arrival.
        surface.update(selected: barcelona.id, overview: overview, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        XCTAssertEqual(surface.planeFlight?.began, flight.began)
        surface.displayFrame(at: flight.began)
        XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, start.centerCoordinate.latitude, accuracy: 0.00001)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, start.centerCoordinateDistance, accuracy: 1)
        let leg = flight.itinerary.legs[0]
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.75, 0.99, 1] {
            surface.displayFrame(at: flight.began + flight.departureDuration + leg.durationSeconds * fraction + 0.000001)
            let expected = leg.coordinate(at: fraction)
            let jet = try XCTUnwrap(surface.planePosition)
            XCTAssertEqual(jet.coordinate.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(jet.coordinate.longitude, expected.longitude, accuracy: 0.00001)
            XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, expected.latitude, accuracy: 0.00001)
            XCTAssertEqual(surface.map.camera.centerCoordinate.longitude, expected.longitude, accuracy: 0.00001)
            let trail = try XCTUnwrap(surface.projectedTrailEnd)
            let projectedJet = try XCTUnwrap(surface.projectedJetPosition)
            XCTAssertEqual(trail.x, projectedJet.x, accuracy: 0.01)
            XCTAssertEqual(trail.y, projectedJet.y, accuracy: 0.01)
        }
        XCTAssertNil(surface.planeFlight)
        let end = surface.map.camera.copy() as! MKMapCamera
        surface.displayFrame(at: flight.began + 30)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, end.centerCoordinateDistance, accuracy: 1)
    }

    @MainActor func testRedirectAndOverviewCancelDoNotTeleportToDestination() throws {
        let surface = SeasonGlobeSurface(onSelect: { _ in })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let races = Season2026.races
        let overviewToken = UUID()
        surface.update(selected: races[4].id, overview: overviewToken, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        surface.update(selected: races[5].id, overview: overviewToken, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        let first = try XCTUnwrap(surface.planeFlight)
        surface.displayFrame(at: first.began + first.departureDuration + first.itinerary.durationSeconds / 2)
        let mid = try XCTUnwrap(surface.planePosition).coordinate
        let trail = try XCTUnwrap(surface.projectedTrailEnd)
        let jet = try XCTUnwrap(surface.projectedJetPosition)
        XCTAssertEqual(trail.x, jet.x, accuracy: 0.01)
        XCTAssertEqual(trail.y, jet.y, accuracy: 0.01)
        surface.update(selected: races[6].id, overview: overviewToken, now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        let next = try XCTUnwrap(surface.planeFlight)
        XCTAssertEqual(next.itinerary.legs[0].from.latitude, mid.latitude, accuracy: 0.00001)
        surface.displayFrame(at: next.began)
        XCTAssertEqual(surface.map.camera.centerCoordinate.latitude, mid.latitude, accuracy: 0.00001)
        surface.displayFrame(at: next.began + next.itinerary.durationSeconds / 2)
        let redirectedTrail = try XCTUnwrap(surface.projectedTrailEnd)
        let redirectedJet = try XCTUnwrap(surface.projectedJetPosition)
        XCTAssertEqual(redirectedTrail.x, redirectedJet.x, accuracy: 0.01)
        XCTAssertEqual(redirectedTrail.y, redirectedJet.y, accuracy: 0.01)
        surface.update(selected: nil, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: false, onComplete: {})
        XCTAssertNil(surface.planeFlight)
        XCTAssertNil(surface.projectedTrailEnd)
        let overview = surface.map.camera.centerCoordinateDistance
        surface.displayFrame(at: next.began + 100)
        XCTAssertEqual(surface.map.camera.centerCoordinateDistance, overview, accuracy: 1)
    }

}

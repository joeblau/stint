import XCTest
import CoreLocation
@testable import Stint

final class GlobeFlightTests: XCTestCase {
    private func race(_ id: String) -> SeasonRace { Season2026.races.first { $0.circuitID == id }! }

    func testOneSecondPerFlightHourAtCruise() {
        let leg = GlobeFlight(from: race("monaco").point.coordinate, to: race("barcelona").point.coordinate)
        XCTAssertEqual(leg.distanceKm, 486, accuracy: 30)
        XCTAssertEqual(leg.durationSeconds, leg.distanceKm / 900, accuracy: 0.0001)
        let longHaul = GlobeFlight(from: race("melbourne").point.coordinate, to: race("shanghai").point.coordinate)
        XCTAssertEqual(longHaul.durationSeconds, longHaul.distanceKm / 900, accuracy: 0.0001)
        XCTAssertGreaterThan(longHaul.durationSeconds, 8)
        XCTAssertEqual(GlobeFlight(from: race("monaco").point.coordinate, to: race("monaco").point.coordinate).durationSeconds, 0)
    }

    func testGreatCircleEndpointsAndMidpoint() {
        let leg = GlobeFlight(from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                              to: CLLocationCoordinate2D(latitude: 0, longitude: 90))
        XCTAssertEqual(leg.coordinate(at: 0).longitude, 0, accuracy: 0.001)
        XCTAssertEqual(leg.coordinate(at: 1).longitude, 90, accuracy: 0.001)
        XCTAssertEqual(leg.coordinate(at: 0.5).longitude, 45, accuracy: 0.001)
        XCTAssertEqual(leg.distanceKm, .pi / 2 * 6_371, accuracy: 1)
        XCTAssertEqual(leg.altitudeProfile(at: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(leg.altitudeProfile(at: 0.5), 1, accuracy: 0.0001)
        XCTAssertEqual(leg.durationLabel, "11 h 07 min")
    }

    func testItineraryFollowsAdjacentRoundsInEitherDirection() {
        let races = Season2026.races
        let forward = GlobeItinerary.alongCalendar(from: races[0], to: races[3], races: races)
        XCTAssertEqual(forward.legs.count, 3)
        XCTAssertEqual(forward.rounds, [races[0].id, races[1].id, races[2].id, races[3].id])
        XCTAssertEqual(forward.durationSeconds, forward.legs.map(\.durationSeconds).reduce(0, +), accuracy: 0.0001)
        let backward = GlobeItinerary.alongCalendar(from: races[3], to: races[1], races: races)
        XCTAssertEqual(backward.rounds, [races[3].id, races[2].id, races[1].id])
        XCTAssertEqual(backward.legs.first?.from.latitude, races[3].point.latitude)
        XCTAssertTrue(GlobeItinerary.alongCalendar(from: races[2], to: races[2], races: races).isEmpty)
    }

    func testPositionWalksLegsByWallTime() throws {
        let races = Season2026.races
        let trip = GlobeItinerary.alongCalendar(from: races[0], to: races[2], races: races)
        let first = trip.legs[0]
        let start = try XCTUnwrap(trip.position(at: 0))
        XCTAssertEqual(start.legIndex, 0)
        XCTAssertEqual(start.coordinate.latitude, races[0].point.latitude, accuracy: 0.0001)
        let secondLeg = try XCTUnwrap(trip.position(at: first.durationSeconds + 0.01))
        XCTAssertEqual(secondLeg.legIndex, 1)
        let end = try XCTUnwrap(trip.position(at: trip.durationSeconds + 5))
        XCTAssertEqual(end.legIndex, 1)
        XCTAssertEqual(end.legProgress, 1, accuracy: 0.0001)
        XCTAssertEqual(end.coordinate.latitude, races[2].point.latitude, accuracy: 0.0001)
        XCTAssertEqual(end.progress, 1, accuracy: 0.0001)
        XCTAssertNil(GlobeItinerary(legs: [], rounds: []).position(at: 1))
    }
}

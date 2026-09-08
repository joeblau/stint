import XCTest
@testable import Stint

final class PlaneFlightSurfaceTests: XCTestCase {
    @MainActor func testFlightStartsBetweenSelections() throws {
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
        let trip = try XCTUnwrap(surface.planeFlight?.itinerary)
        // Monaco and Melbourne are not adjacent: the jet follows the calendar through every round between them.
        XCTAssertEqual(trip.rounds.count, abs(monaco.round - melbourne.round) + 1)
        XCTAssertEqual(trip.legs.count, abs(monaco.round - melbourne.round))
        XCTAssertGreaterThan(trip.distanceKm, 16_000)
        XCTAssertEqual(trip.durationSeconds, trip.distanceKm / GlobeFlight.cruiseKPH * GlobeFlight.secondsPerHour, accuracy: 0.001)
    }

    @MainActor func testFlightRespectsReduceMotion() {
        let surface = SeasonGlobeSurface(onSelect: { _ in })
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        let monaco = Season2026.races.first { $0.circuitID == "monaco" }!
        let melbourne = Season2026.races.first { $0.circuitID == "melbourne" }!
        surface.update(selected: monaco.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: true, onComplete: {})
        surface.update(selected: melbourne.id, overview: UUID(), now: Date(), active: true,
                       flight: nil, reduceMotion: true, onComplete: {})
        XCTAssertNil(surface.planeFlight, "Reduce Motion skips the flight")
    }
}

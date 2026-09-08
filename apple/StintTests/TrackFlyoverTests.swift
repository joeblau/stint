import XCTest
import MapKit
@testable import Stint

final class TrackFlyoverTests: XCTestCase {
    private func flyover(_ circuit: String = "monaco") throws -> TrackFlyover {
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == circuit })
        return TrackFlyover(circuit: try race.circuit.loadCircuit())
    }

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude).distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func testPassSettlesLapsAndPullsBack() throws {
        let pass = try flyover()
        let start = MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 43.7, longitude: 7.4),
                                fromDistance: 300_000, pitch: 0, heading: 0)
        XCTAssertEqual(pass.duration, 31.5, accuracy: 0.001)
        let opening = pass.camera(at: 0, from: start)
        XCTAssertEqual(opening.centerCoordinateDistance, 300_000, accuracy: 1)
        XCTAssertEqual(opening.pitch, 0, accuracy: 0.01)
        let settled = pass.camera(at: TrackFlyover.settleDuration, from: start)
        XCTAssertEqual(settled.pitch, TrackFlyover.overviewPitch, accuracy: 0.5)
        XCTAssertLessThan(meters(settled.centerCoordinate, pass.center), 50)
        XCTAssertGreaterThan(settled.centerCoordinateDistance, 2_900)
        let midLap = pass.camera(at: TrackFlyover.settleDuration + TrackFlyover.lapDuration / 2, from: start)
        XCTAssertEqual(midLap.centerCoordinateDistance, TrackFlyover.chaseDistance, accuracy: 1)
        XCTAssertEqual(midLap.pitch, TrackFlyover.chasePitch, accuracy: 0.5)
        let onTrack = pass.route.points.contains { meters($0.coordinate, midLap.centerCoordinate) < 30 }
        XCTAssertTrue(onTrack, "The chase camera aims at the centerline")
        let final = pass.camera(at: pass.duration + 10, from: start)
        XCTAssertEqual(final.pitch, TrackFlyover.finalPitch, accuracy: 0.5)
        XCTAssertLessThan(meters(final.centerCoordinate, pass.center), 50)
    }

    func testChaseHeadingTurnsSmoothly() throws {
        let pass = try flyover("silverstone")
        var previous = pass.chaseCamera(atLap: 0).heading
        for step in 1...200 {
            let heading = pass.chaseCamera(atLap: Double(step) / 200).heading
            let turn = abs((heading - previous + 540).truncatingRemainder(dividingBy: 360) - 180)
            XCTAssertLessThan(turn, 20, "Heading jumped \(turn)° at step \(step)")
            previous = heading
        }
    }
}

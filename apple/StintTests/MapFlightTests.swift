import XCTest
import MapKit
@testable import Stint

final class MapFlightTests: XCTestCase {
    func testFlightUsesShortDatelinePathAndMonotonicZoom() {
        let start = MKMapCamera(lookingAtCenter: .init(latitude: 20, longitude: 179), fromDistance: 40_000_000, pitch: 0, heading: 350)
        let end = MKMapCamera(lookingAtCenter: .init(latitude: 35, longitude: -179), fromDistance: 100, pitch: 75, heading: 10)
        var previous = start.centerCoordinateDistance
        for tick in 0...120 {
            let camera = MapFlight.camera(from: start, to: end, progress: Double(tick) / 120)
            XCTAssertLessThanOrEqual(camera.centerCoordinateDistance, previous + 0.001)
            XCTAssertGreaterThan(abs(camera.centerCoordinate.longitude), 178)
            XCTAssertGreaterThanOrEqual(camera.pitch, 0)
            XCTAssertLessThanOrEqual(camera.pitch, 75)
            previous = camera.centerCoordinateDistance
        }
        let last = MapFlight.camera(from: start, to: end, progress: 1)
        XCTAssertEqual(last.centerCoordinateDistance, end.centerCoordinateDistance, accuracy: 0.001)
        XCTAssertEqual(last.centerCoordinate.latitude, end.centerCoordinate.latitude, accuracy: 0.001)
        let firstStep = MapFlight.camera(from: start, to: end, progress: 0.001)
        XCTAssertEqual(firstStep.pitch, start.pitch, accuracy: 0.001)
    }
}

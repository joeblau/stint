import XCTest
import MapKit
@testable import Stint

final class GroundProjectionTests: XCTestCase {
    @MainActor func testProjectionMatchesMapKitAtOverviewAndChaseAngles() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        map.isPitchEnabled = true
        let center = GeoPoint(latitude: 43.738, longitude: 7.425)
        for distance in [100.0, 3500, 12000] {
            for pitch in [0.0, 48, 75] {
                for heading in [0.0, 130] {
                    map.camera = MKMapCamera(lookingAtCenter: center.coordinate, fromDistance: distance, pitch: pitch, heading: heading)
                    let camera = map.camera
                    let origin = MKMapPoint(camera.centerCoordinate)
                    let extent = min(1000, max(10, camera.centerCoordinateDistance * 0.15))
                        * MKMapPointsPerMeterAtLatitude(camera.centerCoordinate.latitude)
                    let corners = GroundProjection.samplePoints(origin: origin, extent: extent).map { map.convert($0.coordinate, toPointTo: map) }
                    let projection = try XCTUnwrap(GroundProjection(origin: origin, extent: extent, corners: corners))
                    for x in -2...2 {
                        for y in -2...2 {
                            let coordinate = MKMapPoint(x: origin.x + Double(x) * extent / 2,
                                                        y: origin.y + Double(y) * extent / 2).coordinate
                            let point = GeoPoint(latitude: coordinate.latitude, longitude: coordinate.longitude)
                            let expected = map.convert(coordinate, toPointTo: map)
                            let actual = projection.project(point)
                            XCTAssertEqual(actual.x, expected.x, accuracy: 0.75)
                            XCTAssertEqual(actual.y, expected.y, accuracy: 0.75)
                        }
                    }
                }
            }
        }
    }

    @MainActor func testLocalTangentMatchesNativeMapAtCloseZoom() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1280, height: 820))
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat)
        let point = GeoPoint(latitude: 43.738, longitude: 7.425)
        for pitch in [0.0, 48, 75] {
            map.camera = MKMapCamera(lookingAtCenter: point.coordinate, fromDistance: 100, pitch: pitch, heading: 130)
            let origin = MKMapPoint(map.camera.centerCoordinate)
            let extent = 20 * MKMapPointsPerMeterAtLatitude(point.latitude)
            let corners = GroundProjection.samplePoints(origin: origin, extent: extent).map { map.convert($0.coordinate, toPointTo: map) }
            let projection = try XCTUnwrap(GroundProjection(origin: origin, extent: extent, corners: corners))
            for bearing in [0.0, 45, 90, 180, 270] {
                let a = map.convert(point.offset(meters: 0.1, bearing: bearing + 180).coordinate, toPointTo: map)
                let b = map.convert(point.offset(meters: 0.1, bearing: bearing).coordinate, toPointTo: map)
                let tangent = projection.tangent(at: point, bearing: bearing)
                XCTAssertEqual(tangent.dx, (b.x - a.x) / 0.2, accuracy: 0.02)
                XCTAssertEqual(tangent.dy, (b.y - a.y) / 0.2, accuracy: 0.02)
            }
        }
    }

    func testDegenerateProjectionIsRejected() {
        XCTAssertNil(GroundProjection(origin: MKMapPoint(x: 0, y: 0), extent: 1,
                                      corners: Array(repeating: .zero, count: 4)))
    }
}

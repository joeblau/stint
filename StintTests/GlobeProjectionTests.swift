import XCTest
import CoreLocation
@testable import Stint

final class GlobeProjectionTests: XCTestCase {
    func testCenterAndHiddenHemisphere() throws {
        let size = CGSize(width: 1000, height: 800)
        let center = CLLocationCoordinate2D(latitude: 20, longitude: 15)
        let point = try XCTUnwrap(GlobeProjection.point(center, center: center, distance: 40_000_000, size: size))
        XCTAssertEqual(point.x, 500, accuracy: 0.001)
        XCTAssertEqual(point.y, 400, accuracy: 0.001)
        XCTAssertNil(GlobeProjection.point(.init(latitude: -20, longitude: -165), center: center,
                                          distance: 40_000_000, size: size))
    }

    func testProjectedPointsRemainInsideGlobeLimbAcrossDateline() {
        let size = CGSize(width: 1000, height: 800)
        let radius = 6_371_000.0
        let distance = 40_000_000.0
        let focalLength = 800 / (2 * tan(Double.pi / 12))
        let limb = focalLength * radius / sqrt(pow(radius + distance, 2) - radius * radius)
        for longitude in stride(from: -180.0, through: 180, by: 5) {
            for latitude in stride(from: -85.0, through: 85, by: 5) {
                if let point = GlobeProjection.point(.init(latitude: latitude, longitude: longitude),
                                                      center: .init(latitude: 0, longitude: 179), distance: distance, size: size) {
                    XCTAssertLessThanOrEqual(hypot(point.x - 500, point.y - 400), limb + 0.001)
                }
            }
        }
    }
}

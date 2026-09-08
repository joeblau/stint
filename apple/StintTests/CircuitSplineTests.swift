import XCTest
@testable import Stint

final class CircuitSplineTests: XCTestCase {
    private let anchors = [
        GeoPoint(latitude: 43.730, longitude: 7.420),
        GeoPoint(latitude: 43.731, longitude: 7.420),
        GeoPoint(latitude: 43.731, longitude: 7.421),
        GeoPoint(latitude: 43.730, longitude: 7.421),
        GeoPoint(latitude: 43.730, longitude: 7.420)
    ]

    func testDenseRouteIsClosedAndStillPassesThroughAnchors() {
        let route = CircuitRoute.smoothed(points: anchors)
        XCTAssertGreaterThan(route.points.count, 100)
        XCTAssertEqual(route.points.first, route.points.last)
        for anchor in anchors {
            XCTAssertTrue(route.points.contains {
                abs($0.latitude - anchor.latitude) < 0.0000001 && abs($0.longitude - anchor.longitude) < 0.0000001
            })
        }
        XCTAssertTrue(route.points.allSatisfy(\.isValid))
    }

    func testHeadingIsContinuousAcrossStartFinish() {
        let route = CircuitRoute.smoothed(points: anchors, spacing: 0.5)
        let before = route.point(at: -0.5).bearing(to: route.point(at: 0))
        let after = route.point(at: 0).bearing(to: route.point(at: 0.5))
        let difference = (after - before + 540).truncatingRemainder(dividingBy: 360) - 180
        XCTAssertLessThan(abs(difference), 3)
    }

    func testDuplicateAnchorsDoNotProduceInvalidPoints() {
        let route = CircuitRoute.smoothed(points: [anchors[0]] + anchors + [anchors[0]])
        XCTAssertTrue(route.points.allSatisfy(\.isValid))
        XCTAssertTrue(route.length.isFinite)
        XCTAssertGreaterThan(route.length, 0)
    }
}

import CoreLocation
import XCTest
@testable import Stint

final class TrackSurfaceLibraryTests: XCTestCase {
    private let expectedCircuits: Set<String> = ["austin", "baku", "barcelona", "budapest", "interlagos", "jeddah",
        "lasvegas", "lusail", "madrid", "melbourne", "mexicocity", "miami", "monaco", "montreal", "monza",
        "sakhir", "shanghai", "silverstone", "singapore", "spafrancorchamps", "spielberg", "suzuka",
        "yasmarina", "zandvoort"]

    private func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func testDecodesAllMeasuredCircuits() {
        for id in expectedCircuits {
            XCTAssertNotNil(TrackSurfaceLibrary.shared.surface(for: id), "missing measured surface for \(id)")
        }
        // Circuits without measured data keep the uniform-stroke fallback.
        XCTAssertNil(TrackSurfaceLibrary.shared.surface(for: "sepang"))
        XCTAssertNil(TrackSurfaceLibrary.shared.surface(for: "imola"))
    }

    func testWidthsAndEdgesAreSane() {
        for id in expectedCircuits {
            guard let surface = TrackSurfaceLibrary.shared.surface(for: id) else { continue }
            XCTAssertEqual(surface.leftEdge.count, surface.centerline.count + 1, id)
            XCTAssertEqual(surface.rightEdge.count, surface.centerline.count + 1, id)
            XCTAssertEqual(distance(surface.leftEdge[0], surface.leftEdge.last!), 0, accuracy: 0.001, id)
            for index in surface.centerline.indices {
                let fullWidth = surface.halfWidthLeft[index] + surface.halfWidthRight[index]
                XCTAssertTrue((5...30).contains(fullWidth), "\(id)[\(index)] full width \(fullWidth)")
                // Edge offset lands within a meter of the recorded half-widths.
                XCTAssertEqual(distance(surface.centerline[index], surface.leftEdge[index]),
                               surface.halfWidthLeft[index], accuracy: 1, "\(id)[\(index)]")
                XCTAssertEqual(distance(surface.centerline[index], surface.rightEdge[index]),
                               surface.halfWidthRight[index], accuracy: 1, "\(id)[\(index)]")
            }
        }
    }

    func testMonacoLengthIsStreetCircuitScale() throws {
        let surface = try XCTUnwrap(TrackSurfaceLibrary.shared.surface(for: "monaco"))
        var length = 0.0
        for index in 1...surface.centerline.count {
            length += distance(surface.centerline[index - 1], surface.centerline[index % surface.centerline.count])
        }
        XCTAssertEqual(length, 3_337, accuracy: 200)
    }

    func testKerbPolygons() {
        for id in expectedCircuits {
            guard let surface = TrackSurfaceLibrary.shared.surface(for: id) else { continue }
            XCTAssertFalse(surface.kerbs.isEmpty, id)
            for kerb in surface.kerbs {
                XCTAssertGreaterThanOrEqual(kerb.polygon.count, 3, id)
                XCTAssertTrue(kerb.polygon.allSatisfy(CLLocationCoordinate2DIsValid), id)
            }
        }
        // Lusail has strips confirmed against satellite imagery; Monaco is fully curvature-synthetic.
        XCTAssertTrue(TrackSurfaceLibrary.shared.surface(for: "lusail")!.kerbs.contains { $0.imagery })
        XCTAssertFalse(TrackSurfaceLibrary.shared.surface(for: "monaco")!.kerbs.contains { $0.imagery })
    }

    func testRibbonClosesAroundCenterline() throws {
        let surface = try XCTUnwrap(TrackSurfaceLibrary.shared.surface(for: "silverstone"))
        let ribbon = surface.ribbon
        XCTAssertEqual(ribbon.count, surface.centerline.count * 2)
        // The ribbon starts on the left edge and ends on the right edge at the same station.
        XCTAssertEqual(ribbon.first!.latitude, surface.leftEdge[0].latitude, accuracy: 0.0000001)
        XCTAssertEqual(ribbon.last!.latitude, surface.rightEdge[0].latitude, accuracy: 0.0000001)
    }
}

import XCTest
import MapKit
@testable import Stint

final class CircuitEdgeOverlayTests: XCTestCase {
    func testBundledMiamiContainsObservedRoadSectorsAndWeakKerbs() throws {
        let doc = try XCTUnwrap(CircuitEdgeDocument.load(circuitID: "miami"))
        XCTAssertEqual(doc.surfaces.count, 1, "The road must be one continuous polygon")
        XCTAssertEqual(doc.surfaces.first?.rings.count, 2, "Only the infield is a hole")
        XCTAssertEqual(Set(doc.lines.compactMap(\.sector)), Set([1, 2, 3]))
        let kerbs = doc.lines.filter { $0.kind == "kerb" }
        XCTAssertFalse(kerbs.isEmpty)
        XCTAssertTrue(kerbs.allSatisfy(\.weak))
        XCTAssertEqual(Set(kerbs.compactMap(\.reviewID)).count, 25, "All reviewed entry/apex/exit strips must be bundled")
        for id in ["t1-apex", "t4-apex", "t8-exit", "t15-apex", "t16-apex", "t19-apex-exit"] {
            XCTAssertTrue(kerbs.contains { $0.reviewID == id }, "Missing reviewed kerb: \(id)")
        }
        XCTAssertTrue(doc.lines.allSatisfy { $0.pixels == ($0.kind == "kerb" ? 6 : 2) })
        let circuit = try XCTUnwrap(DemoCircuit.allCases.first { $0.id == "miami" }).loadCircuit()
        let overlays = CircuitTrackOverlays.make(document: doc, circuit: circuit)
        XCTAssertFalse(overlays.contains { $0 is TrackSurfaceOverlay }, "Miami must load the extracted asset, not the constant-width fallback")
    }

    func testMiamiRolloutUsesAppleTerrainAndLeavesOtherCircuitsDisabled() throws {
        XCTAssertEqual(MiamiSurfacePolicy.elevation(circuitID: "miami"), .realistic)
        for circuit in DemoCircuit.allCases where circuit.id != "miami" {
            XCTAssertFalse(MiamiSurfacePolicy.isEnabled(circuitID: circuit.id))
            XCTAssertEqual(MiamiSurfacePolicy.elevation(circuitID: circuit.id), .flat)
            XCTAssertNil(try CircuitEdgeDocument.load(circuitID: circuit.id))
        }
        XCTAssertEqual(MiamiSurfacePolicy.elevation(circuitID: nil), .flat)
    }

    func testRejectsBundledAssetWithAMissingReviewedKerb() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "miami.surface", withExtension: "geojson"))
        var raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let features = raw["features"] as! [[String: Any]]
        raw["features"] = features.filter { ($0["properties"] as? [String: Any])?["reviewID"] as? String != "t8-exit" }
        XCTAssertThrowsError(try CircuitEdgeDocument(data: JSONSerialization.data(withJSONObject: raw)))
    }

    private func document(coordinates: String = "[[-80.24,25.95],[-80.23,25.96]]", extras: String = "") -> Data {
        Data("""
        {"type":"FeatureCollection","features":[{"type":"Feature","properties":{
        "kind":"sector_edge","sector":1,"color":"#00FFFF","timingYear":2026,"timingSource":"https://www.fia.com/example",
        "weak":false,"confidence":0.7,"strokeUnits":"screen-pixels","strokePixels":2,"edgeSide":"inner"\(extras)
        },"geometry":{"type":"LineString","coordinates":\(coordinates)}}]}
        """.utf8)
    }

    func testDecodesLongitudeLatitudeAndSector() throws {
        let line = try XCTUnwrap(CircuitEdgeDocument(data: document()).lines.first)
        XCTAssertEqual(line.points[0].latitude, 25.95)
        XCTAssertEqual(line.points[0].longitude, -80.24)
        XCTAssertEqual(line.sector, 1)
        XCTAssertEqual(line.pixels, 2)
    }

    func testRejectsAltitudeAndUnboundedCoordinates() {
        XCTAssertThrowsError(try CircuitEdgeDocument(data: document(coordinates: "[[-80.24,25.95,0],[-80.23,25.96,0]]")))
        XCTAssertThrowsError(try CircuitEdgeDocument(data: document(coordinates: "[[-180.24,25.95],[-80.23,25.96]]")))
    }

    func testRejectsWrongSectorColorAndWorldSpaceStroke() {
        let text = String(data: document(), encoding: .utf8)!
        XCTAssertThrowsError(try CircuitEdgeDocument(data: Data(text.replacingOccurrences(of: "#00FFFF", with: "#FF00FF").utf8)))
        XCTAssertThrowsError(try CircuitEdgeDocument(data: Data(text.replacingOccurrences(of: "screen-pixels", with: "meters").utf8)))
    }

    func testStrokeHasConstantDevicePixelWidthAcrossZoomAndDisplayScale() {
        for zoom in [0.0001, 0.01, 1.0, 8.0] {
            for scale in [1.0, 2.0, 3.0] {
                let width = CircuitEdgeRenderer.mapWidth(pixels: 2, zoomScale: zoom, displayScale: scale)
                XCTAssertEqual(width * zoom * scale, 2, accuracy: 0.000001)
            }
        }
    }

    func testKerbsPaintAlternatingRedAndWhiteWithoutTransparentGaps() throws {
        let line = CircuitEdgeDocument.Line(points: [GeoPoint(latitude: 25.95, longitude: -80.24),
                                                    GeoPoint(latitude: 25.95, longitude: -80.239)],
                                            sector: nil, weak: true, pixels: 6, kind: "kerb")
        let overlay = CircuitEdgeOverlay(line: line)
        let renderer = CircuitEdgeRenderer(edge: overlay)
        renderer.displayScale = 1
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 64, bitsPerComponent: 8,
                                             bytesPerRow: 1024, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let start = renderer.point(for: MKMapPoint(line.points[0].coordinate))
        let end = renderer.point(for: MKMapPoint(line.points[1].coordinate))
        let scale = 236 / (end.x - start.x)
        context.translateBy(x: 10, y: 32)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -start.x, y: -start.y)
        renderer.draw(overlay.boundingMapRect, zoomScale: scale, in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        var red = 0, white = 0, transitions = 0, previousRed = false
        for x in 20..<236 {
            let index = 32 * 1024 + x * 4
            XCTAssertEqual(bytes[index + 3], 255, "White stripes must be opaque, not missing dashes")
            let isRed = bytes[index] > 200 && bytes[index + 1] < 80
            if isRed { red += 1 }
            if bytes[index] > 245 && bytes[index + 1] > 245 && bytes[index + 2] > 245 { white += 1 }
            if isRed != previousRed { transitions += 1 }
            previousRed = isRed
        }
        XCTAssertGreaterThan(red, 70)
        XCTAssertGreaterThan(white, 70)
        XCTAssertGreaterThan(transitions, 12, "The line must alternate repeatedly")
    }

    private func asphaltDocument() throws -> CircuitEdgeDocument {
        var doc = try JSONSerialization.jsonObject(with: document()) as! [String: Any]
        var features = doc["features"] as! [[String: Any]]
        let rings = [
            [[-80.25, 25.95], [-80.23, 25.95], [-80.23, 25.97], [-80.25, 25.97], [-80.25, 25.95]],
            [[-80.245, 25.955], [-80.235, 25.955], [-80.235, 25.965], [-80.245, 25.965], [-80.245, 25.955]]
        ]
        features.append(["type": "Feature", "properties": ["kind": "road_surface"],
                         "geometry": ["type": "Polygon", "coordinates": rings]])
        doc["features"] = features
        return try CircuitEdgeDocument(data: JSONSerialization.data(withJSONObject: doc))
    }

    func testMiamiRetainsExistingAsphaltWhenMeasuredAssetIsMissing() throws {
        let miami = try XCTUnwrap(DemoCircuit.allCases.first { $0.id == "miami" })
        let overlays = CircuitTrackOverlays.make(document: nil, circuit: try miami.loadCircuit())
        XCTAssertEqual(overlays.count, 1)
        XCTAssertTrue(overlays[0] is TrackSurfaceOverlay)
    }

    func testMeasuredAsphaltIsBelowSectorEdgesWithoutAnApproximateFallback() throws {
        let overlays = CircuitTrackOverlays.make(document: try asphaltDocument(), circuit: [])
        XCTAssertEqual(overlays.count, 2)
        XCTAssertTrue(overlays[0] is CircuitAsphaltOverlay)
        XCTAssertTrue(overlays[1] is CircuitEdgeOverlay)
    }

    func testPartialMeasuredDocumentDoesNotFabricateAPolygon() throws {
        let doc = try CircuitEdgeDocument(data: document())
        let overlays = CircuitTrackOverlays.make(document: doc, circuit: try DemoCircuit.monaco.loadCircuit())
        XCTAssertEqual(overlays.count, 1)
        XCTAssertTrue(overlays[0] is CircuitEdgeOverlay)
    }

    func testAsphaltActuallyPaintsNeutralPixelsAndLeavesInfieldTransparent() throws {
        let surface = try XCTUnwrap(asphaltDocument().surfaces.first)
        let overlay = CircuitAsphaltOverlay(surface: surface)
        let renderer = CircuitAsphaltRenderer(asphalt: overlay)
        let context = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                             bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bounds = renderer.rect(for: overlay.boundingMapRect)
        context.scaleBy(x: 100 / bounds.width, y: 100 / bounds.height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        renderer.draw(overlay.boundingMapRect, zoomScale: 1, in: context)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        let asphalt = 50 * 400 + 12 * 4, infield = 50 * 400 + 50 * 4
        XCTAssertEqual(bytes[asphalt + 3], 255, "The road surface must actually be filled")
        XCTAssertEqual(bytes[asphalt], bytes[asphalt + 1])
        XCTAssertEqual(bytes[asphalt], bytes[asphalt + 2], "Asphalt must not inherit sector color")
        XCTAssertEqual(bytes[infield + 3], 0, "Do not fill the circuit's infield")
    }
}

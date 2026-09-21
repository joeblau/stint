import Foundation
import MapKit

/// This rollout is limited to Miami. MapKit owns terrain; source geometry stays 2D.
enum MiamiSurfacePolicy {
    static func isEnabled(circuitID: String?) -> Bool { circuitID == "miami" }

    static func elevation(circuitID: String?) -> MKMapConfiguration.ElevationStyle {
        isEnabled(circuitID: circuitID) ? .realistic : .flat
    }
}

/// Native MapKit overlays accept only two-dimensional coordinates. Asphalt stays neutral;
/// sector colors belong exclusively to the edge lines.
struct CircuitEdgeDocument {
    struct Surface {
        let rings: [[GeoPoint]]
    }
    struct Line {
        let points: [GeoPoint]
        let sector: Int?
        let weak: Bool
        let pixels: CGFloat
        let kind: String
        var reviewID: String? = nil
    }
    let lines: [Line]
    let surfaces: [Surface]

    enum Invalid: Error { case document, feature, coordinate, styling }

    init(data: Data) throws {
        guard let doc = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              doc["type"] as? String == "FeatureCollection",
              let features = doc["features"] as? [[String: Any]] else { throw Invalid.document }
        var result: [Line] = []
        var surfaces: [Surface] = []
        func points(_ raw: Any?) throws -> [GeoPoint] {
            guard let coordinates = raw as? [[Double]], coordinates.count >= 2 else { throw Invalid.coordinate }
            return try coordinates.map { c in
                guard c.count == 2 else { throw Invalid.coordinate }
                let point = GeoPoint(latitude: c[1], longitude: c[0])
                guard point.isValid else { throw Invalid.coordinate }
                return point
            }
        }
        for feature in features {
            guard feature["type"] as? String == "Feature",
                  let properties = feature["properties"] as? [String: Any],
                  let kind = properties["kind"] as? String,
                  let geometry = feature["geometry"] as? [String: Any] else { throw Invalid.feature }
            if kind == "road_surface" {
                guard geometry["type"] as? String == "Polygon", let rings = geometry["coordinates"] as? [Any], !rings.isEmpty,
                      properties["color"] == nil, properties["sector"] == nil else { throw Invalid.feature }
                let decoded = try rings.map { ring in
                    let ps = try points(ring)
                    guard ps.count >= 4, ps.first == ps.last else { throw Invalid.coordinate }
                    return ps
                }
                surfaces.append(Surface(rings: decoded))
                continue
            }
            guard ["sector_edge", "road_edge", "kerb"].contains(kind), geometry["type"] as? String == "LineString",
                  properties["strokeUnits"] as? String == "screen-pixels",
                  let pixels = properties["strokePixels"] as? Double, pixels.isFinite, pixels > 0, pixels <= 8,
                  let weak = properties["weak"] as? Bool,
                  let confidence = properties["confidence"] as? Double, confidence.isFinite, (0...1).contains(confidence),
                  ["inner", "outer"].contains(properties["edgeSide"] as? String ?? "") else { throw Invalid.styling }
            var sector: Int?
            if kind == "sector_edge" {
                guard let value = properties["sector"] as? Int, (1...3).contains(value),
                      properties["color"] as? String == ["#00FFFF", "#FF00FF", "#FFFF00"][value - 1],
                      let source = properties["timingSource"] as? String, source.hasPrefix("https://"),
                      properties["timingYear"] as? Int != nil else { throw Invalid.styling }
                sector = value
            } else if properties["sector"] != nil || properties["color"] != nil { throw Invalid.styling }
            if kind == "kerb" && (!weak || confidence > 0.3) { throw Invalid.styling }
            result.append(Line(points: try points(geometry["coordinates"]), sector: sector,
                               weak: weak || confidence < 0.4, pixels: pixels, kind: kind,
                               reviewID: properties["reviewID"] as? String))
        }
        if let metadata = doc["metadata"] as? [String: Any], let review = metadata["kerbReview"] as? [String: Any],
           let strips = review["curbs"] as? [[String: Any]] {
            let expected = strips.compactMap { $0["id"] as? String }
            guard expected.count == strips.count,
                  result.filter { $0.kind == "kerb" }.allSatisfy({ $0.reviewID != nil }),
                  Set(result.filter { $0.kind == "kerb" }.compactMap(\.reviewID)) == Set(expected) else { throw Invalid.feature }
        }
        lines = result
        self.surfaces = surfaces
    }

    static func load(circuitID: String, bundle: Bundle = .main) throws -> CircuitEdgeDocument? {
        guard MiamiSurfacePolicy.isEnabled(circuitID: circuitID) else { return nil }
        guard let url = bundle.url(forResource: "\(circuitID).surface", withExtension: "geojson") else { return nil }
        return try CircuitEdgeDocument(data: Data(contentsOf: url))
    }
}

/// Shared ordering for the race map and calendar: neutral asphalt below colored edges.
enum CircuitTrackOverlays {
    static func make(document: CircuitEdgeDocument?, circuit: [GeoPoint]) -> [MKOverlay] {
        if let document {
            return document.surfaces.map { CircuitAsphaltOverlay(surface: $0) } as [MKOverlay]
                + document.lines.filter { $0.kind == "kerb" }.map { CircuitEdgeOverlay(line: $0) }
                + document.lines.filter { $0.kind != "kerb" }.map { CircuitEdgeOverlay(line: $0) }
        }
        // Keep the existing approximate 12 m visualization until measured geometry is available.
        return TrackSurfaceOverlay(points: circuit).map { [$0] } ?? []
    }
}

final class CircuitAsphaltOverlay: NSObject, MKOverlay {
    let rings: [[MKMapPoint]]
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(surface: CircuitEdgeDocument.Surface) {
        rings = surface.rings.map { $0.map { MKMapPoint($0.coordinate) } }
        let coordinates = surface.rings[0].map(\.coordinate)
        let exterior = MKPolyline(coordinates: coordinates, count: coordinates.count)
        coordinate = exterior.coordinate
        boundingMapRect = exterior.boundingMapRect
        super.init()
    }
}

final class CircuitAsphaltRenderer: MKOverlayRenderer {
    private let path = CGMutablePath()

    init(asphalt: CircuitAsphaltOverlay) {
        super.init(overlay: asphalt)
        for ring in asphalt.rings {
            for (index, p) in ring.enumerated() {
                let local = point(for: p)
                if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
            }
            path.closeSubpath()
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        context.setFillColor(CGColor(gray: 0.19, alpha: 1))
        context.addPath(path)
        // Preserve the circuit's infield and any other holes, regardless of ring winding.
        context.drawPath(using: .eoFill)
    }
}

final class CircuitEdgeOverlay: NSObject, MKOverlay {
    let line: CircuitEdgeDocument.Line
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect

    init(line: CircuitEdgeDocument.Line) {
        self.line = line
        let coords = line.points.map(\.coordinate)
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        coordinate = polyline.coordinate
        boundingMapRect = polyline.boundingMapRect.insetBy(dx: -128, dy: -128)
        super.init()
    }
}

final class CircuitEdgeRenderer: MKOverlayRenderer {
    private let path = CGMutablePath()
    private let line: CircuitEdgeDocument.Line
    /// MKOverlayRenderer.contentScaleFactor is get-only on macOS, so keep our own.
    var displayScale: CGFloat = 2

    static func mapWidth(pixels: CGFloat, zoomScale: MKZoomScale, displayScale: CGFloat) -> CGFloat {
        pixels / (max(zoomScale, 0.000000001) * max(displayScale, 1))
    }

    init(edge: CircuitEdgeOverlay) {
        line = edge.line
        super.init(overlay: edge)
        for (i, coordinate) in line.points.enumerated() {
            let p = point(for: MKMapPoint(coordinate.coordinate))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect(for: mapRect))
        let width = Self.mapWidth(pixels: line.pixels, zoomScale: zoomScale, displayScale: displayScale)
        let color: CGColor
        switch line.sector {
        case 1: color = CGColor(red: 0, green: 1, blue: 1, alpha: 1)
        case 2: color = CGColor(red: 1, green: 0, blue: 1, alpha: 1)
        case 3: color = CGColor(red: 1, green: 1, blue: 0, alpha: 1)
        default: color = CGColor(gray: line.kind == "kerb" ? 0.7 : 0.95, alpha: 1)
        }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        if line.kind == "kerb" {
            // A solid white underlay keeps every stripe opaque, including the dash gaps.
            // Confidence stays in the source metadata; the requested livery is illustrative.
            context.setLineCap(.butt)
            context.setStrokeColor(CGColor(gray: 1, alpha: 1))
            context.addPath(path)
            context.strokePath()
            context.setStrokeColor(CGColor(red: 0.9, green: 0.13, blue: 0.13, alpha: 1))
            context.setLineDash(phase: 0, lengths: [width * 2, width * 2])
        }
        context.addPath(path)
        context.strokePath()
    }
}

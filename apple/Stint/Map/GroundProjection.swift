import MapKit

/// A flat MapKit map is a projective transform of Mercator ground coordinates.
/// Four native samples determine that transform for the whole field, including
/// perspective at low chase angles. No per-car MapKit conversions are needed.
struct GroundProjection {
    let origin: MKMapPoint
    let extent: Double
    private let a: Double, b: Double, c: Double
    private let d: Double, e: Double, f: Double
    private let g: Double, h: Double

    init?(origin: MKMapPoint, extent: Double, corners: [CGPoint]) {
        guard corners.count == 4, extent > 0,
              corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let p = corners
        let dx1 = Double(p[1].x - p[2].x), dx2 = Double(p[3].x - p[2].x)
        let dy1 = Double(p[1].y - p[2].y), dy2 = Double(p[3].y - p[2].y)
        let dx3 = Double(p[0].x - p[1].x + p[2].x - p[3].x)
        let dy3 = Double(p[0].y - p[1].y + p[2].y - p[3].y)
        let denominator = dx1 * dy2 - dx2 * dy1
        guard abs(denominator) > 0.000001 else { return nil }
        g = (dx3 * dy2 - dx2 * dy3) / denominator
        h = (dx1 * dy3 - dx3 * dy1) / denominator
        a = Double(p[1].x - p[0].x) + g * Double(p[1].x)
        b = Double(p[3].x - p[0].x) + h * Double(p[3].x)
        c = Double(p[0].x)
        d = Double(p[1].y - p[0].y) + g * Double(p[1].y)
        e = Double(p[3].y - p[0].y) + h * Double(p[3].y)
        f = Double(p[0].y)
        self.origin = origin
        self.extent = extent
    }

    static func samplePoints(origin: MKMapPoint, extent: Double) -> [MKMapPoint] {
        [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map {
            MKMapPoint(x: origin.x + $0.0 * extent, y: origin.y + $0.1 * extent)
        }
    }

    func project(_ point: GeoPoint) -> CGPoint {
        let mercator = MKMapPoint(point.coordinate)
        var dx = mercator.x - origin.x
        let world = MKMapSize.world.width
        if dx > world / 2 { dx -= world }
        if dx < -world / 2 { dx += world }
        let u = (dx / extent + 1) / 2
        let v = ((mercator.y - origin.y) / extent + 1) / 2
        let w = g * u + h * v + 1
        // Behind the horizon must not fold back onto the visible half of the map.
        guard w > 0.000001 else { return CGPoint(x: Double.infinity, y: Double.infinity) }
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }
}

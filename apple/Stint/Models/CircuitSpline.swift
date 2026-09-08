import Foundation
import simd

extension CircuitRoute {
    /// Densifies bundled demo outlines with a closed centripetal Catmull–Rom spline.
    /// Distance-based playback on the resulting route avoids speeding up on sparse sections.
    static func smoothed(points: [GeoPoint], spacing: Double = 2) -> CircuitRoute {
        var anchors: [GeoPoint] = []
        for point in points where point != anchors.last { anchors.append(point) }
        if anchors.first == anchors.last { anchors.removeLast() }
        guard anchors.count >= 3, spacing.isFinite, spacing > 0 else { return CircuitRoute(points: points) }

        let origin = anchors[0]
        let longitudeScale = 111_320 * cos(origin.latitude * .pi / 180)
        let vectors = anchors.map {
            SIMD2(($0.longitude - origin.longitude) * longitudeScale,
                  ($0.latitude - origin.latitude) * 111_320)
        }
        var dense: [GeoPoint] = []
        for index in vectors.indices {
            let count = vectors.count
            let p0 = vectors[(index + count - 1) % count]
            let p1 = vectors[index]
            let p2 = vectors[(index + 1) % count]
            let p3 = vectors[(index + 2) % count]
            // Centripetal knot spacing limits loops and overshoot near tight hairpins.
            let t0 = 0.0
            let t1 = t0 + max(0.001, sqrt(simd_distance(p0, p1)))
            let t2 = t1 + max(0.001, sqrt(simd_distance(p1, p2)))
            let t3 = t2 + max(0.001, sqrt(simd_distance(p2, p3)))
            let steps = max(2, Int(ceil(simd_distance(p1, p2) / spacing)))
            for step in 0..<steps {
                let t = t1 + (t2 - t1) * Double(step) / Double(steps)
                let a1 = blend(p0, p1, from: t0, to: t1, at: t)
                let a2 = blend(p1, p2, from: t1, to: t2, at: t)
                let a3 = blend(p2, p3, from: t2, to: t3, at: t)
                let b1 = blend(a1, a2, from: t0, to: t2, at: t)
                let b2 = blend(a2, a3, from: t1, to: t3, at: t)
                let point = blend(b1, b2, from: t1, to: t2, at: t)
                dense.append(GeoPoint(latitude: origin.latitude + point.y / 111_320,
                                      longitude: origin.longitude + point.x / longitudeScale))
            }
        }
        dense.append(dense[0])
        return CircuitRoute(points: dense)
    }

    private static func blend(_ a: SIMD2<Double>, _ b: SIMD2<Double>, from start: Double,
                              to end: Double, at time: Double) -> SIMD2<Double> {
        ((end - time) * a + (time - start) * b) / (end - start)
    }
}

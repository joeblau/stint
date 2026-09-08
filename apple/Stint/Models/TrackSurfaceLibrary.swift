import Foundation
import CoreLocation

/// Measured 2026 circuit surfaces bundled as `track-surfaces.json` (exported from
/// telemetry/geometry/tracks2026 by telemetry/scripts/export-app-surfaces.ts). Each centerline row is
/// [lat, lon, halfWidthLeft, halfWidthRight] in meters; kerb polygons are [lat, lon] rings flagged by
/// whether satellite imagery confirmed them. Unmeasured circuits have no entry and keep the uniform stroke.
struct TrackSurfaceLibrary {
    struct KerbStrip {
        let polygon: [CLLocationCoordinate2D]
        let imagery: Bool
    }

    struct Surface {
        let centerline: [GeoPoint]
        let halfWidthLeft: [Double]
        let halfWidthRight: [Double]
        /// Closed loops (last point repeats the first): the centerline offset along its local normal.
        let leftEdge: [GeoPoint]
        let rightEdge: [GeoPoint]
        let kerbs: [KerbStrip]

        /// Closed ribbon filling the asphalt: left edge forward, right edge back.
        var ribbon: [CLLocationCoordinate2D] {
            leftEdge.dropLast().map(\.coordinate) + rightEdge.dropLast().reversed().map(\.coordinate)
        }
    }

    static let shared = TrackSurfaceLibrary()

    private let surfaces: [String: Surface]

    private init() {
        guard let url = Bundle.main.url(forResource: "track-surfaces", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            surfaces = [:]
            return
        }
        surfaces = document.circuits.compactMapValues { Surface(circuit: $0) }
    }

    func surface(for circuitID: String) -> Surface? { surfaces[circuitID] }
}

private struct Document: Decodable {
    let circuits: [String: Circuit]
}

private struct Circuit: Decodable {
    let centerline: [[Double]]
    let kerbs: [Kerb]

    struct Kerb: Decodable {
        let polygon: [[Double]]
        let imagery: Bool
    }
}

private extension TrackSurfaceLibrary.Surface {
    init?(circuit: Circuit) {
        let rows = circuit.centerline
        guard rows.count >= 3,
              rows.allSatisfy({ $0.count == 4 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let centerline = rows.map { GeoPoint(latitude: $0[0], longitude: $0[1]) }
        guard centerline.allSatisfy(\.isValid) else { return nil }
        let count = centerline.count
        var leftEdge = [GeoPoint](), rightEdge = [GeoPoint]()
        leftEdge.reserveCapacity(count + 1)
        rightEdge.reserveCapacity(count + 1)
        for index in 0..<count {
            let previous = centerline[(index + count - 1) % count]
            let next = centerline[(index + 1) % count]
            let tangent = previous.bearing(to: next)
            // Left of the direction of travel is 90° counterclockwise from the tangent.
            leftEdge.append(centerline[index].offset(meters: rows[index][2], bearing: tangent - 90))
            rightEdge.append(centerline[index].offset(meters: rows[index][3], bearing: tangent + 90))
        }
        leftEdge.append(leftEdge[0])
        rightEdge.append(rightEdge[0])
        let kerbs = circuit.kerbs.compactMap { kerb -> TrackSurfaceLibrary.KerbStrip? in
            guard kerb.polygon.count >= 3, kerb.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
            else { return nil }
            let polygon = kerb.polygon.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
            guard polygon.allSatisfy(CLLocationCoordinate2DIsValid) else { return nil }
            return TrackSurfaceLibrary.KerbStrip(polygon: polygon, imagery: kerb.imagery)
        }
        self.init(centerline: centerline, halfWidthLeft: rows.map { $0[2] }, halfWidthRight: rows.map { $0[3] },
                  leftEdge: leftEdge, rightEdge: rightEdge, kerbs: kerbs)
    }
}

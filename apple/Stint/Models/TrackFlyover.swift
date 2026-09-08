import Foundation
import MapKit

/// A cinematic pass over a circuit: settle above the track, one low chase lap along the
/// centerline, then pull back to a three-quarter view. Pure timing math; the globe drives the map.
struct TrackFlyover {
    let route: CircuitRoute
    let center: CLLocationCoordinate2D
    let overviewDistance: Double

    static let settleDuration = 2.5
    static let lapDuration = 24.0
    static let pullbackDuration = 5.0
    /// Low and slow: a few hundred meters up, looking well down the track.
    static let chaseDistance = 320.0
    static let chasePitch = 68.0
    static let overviewPitch = 45.0
    static let lookahead = 120.0
    static let blendDuration = 3.0
    /// Heading is the mean of unwrapped bearings over this stretch, so hairpins turn the camera gradually.
    static let headingWindow = 400.0

    var duration: Double { Self.settleDuration + Self.lapDuration + Self.pullbackDuration }

    init(circuit: [GeoPoint]) {
        var points = circuit
        if let first = points.first, points.last != first { points.append(first) }
        route = CircuitRoute.smoothed(points: points, spacing: 4)
        let latitudes = route.points.map(\.latitude)
        let longitudes = route.points.map(\.longitude)
        let latitude = (latitudes.min()! + latitudes.max()!) / 2
        let longitude = (longitudes.min()! + longitudes.max()!) / 2
        center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let northSouth = (latitudes.max()! - latitudes.min()!) * 111_320
        let eastWest = (longitudes.max()! - longitudes.min()!) * 111_320 * cos(latitude * .pi / 180)
        overviewDistance = max(3_000, max(northSouth, eastWest) * 1.9 + 800)
    }

    /// Bearing of travel at `distance` along the lap, averaged over the surrounding stretch of track.
    func heading(at distance: Double) -> Double {
        // Unwrapping keeps a hairpin's bearings continuous (187°, 213°, … 366°, 387°) so their
        // average turns steadily instead of swinging when the samples straddle north.
        let step = 20.0
        var offset = -Self.headingWindow / 2
        var previous: Double?
        var sum = 0.0
        var count = 0.0
        while offset <= Self.headingWindow / 2 {
            var bearing = route.point(at: distance + offset).bearing(to: route.point(at: distance + offset + step))
            if let previous {
                bearing = previous + ((bearing - previous + 540).truncatingRemainder(dividingBy: 360) - 180)
            }
            previous = bearing
            sum += bearing
            count += 1
            offset += step
        }
        return ((sum / count).truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    var overviewCamera: MKMapCamera {
        MKMapCamera(lookingAtCenter: center, fromDistance: overviewDistance, pitch: Self.overviewPitch, heading: heading(at: 0))
    }

    /// The chase camera at `fraction` (0...1) of the lap.
    func chaseCamera(atLap fraction: Double) -> MKMapCamera {
        let distance = min(1, max(0, fraction)) * route.length
        return MKMapCamera(lookingAtCenter: route.point(at: distance + Self.lookahead).coordinate,
                           fromDistance: Self.chaseDistance, pitch: Self.chasePitch, heading: heading(at: distance))
    }

    /// MapKit caps pitch as the camera climbs; 35° is the most it allows at circuit-overview altitude.
    static let finalPitch = 35.0

    var finalCamera: MKMapCamera {
        let end = heading(at: route.length)
        return MKMapCamera(lookingAtCenter: center, fromDistance: overviewDistance * 0.9, pitch: Self.finalPitch,
                           heading: (end + 90).truncatingRemainder(dividingBy: 360))
    }

    /// The camera `seconds` into the pass, starting from wherever the map was.
    func camera(at seconds: Double, from start: MKMapCamera) -> MKMapCamera {
        let t = min(max(0, seconds), duration)
        if t < Self.settleDuration {
            return MapFlight.camera(from: start, to: overviewCamera, progress: t / Self.settleDuration)
        }
        let lapTime = t - Self.settleDuration
        if lapTime < Self.lapDuration {
            let chase = chaseCamera(atLap: lapTime / Self.lapDuration)
            // Blend from the overview into the chase so the first corner does not cut.
            if lapTime < Self.blendDuration {
                return MapFlight.camera(from: overviewCamera, to: chase, progress: lapTime / Self.blendDuration)
            }
            return chase
        }
        let pullback = (lapTime - Self.lapDuration) / Self.pullbackDuration
        return MapFlight.camera(from: chaseCamera(atLap: 1), to: finalCamera, progress: pullback)
    }
}

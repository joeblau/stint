import Foundation
import MapKit

struct MapFlight {
    let id = UUID()
    let start: MKMapCamera?
    let destination: MKMapCamera
    let duration: TimeInterval
    let toGlobe: Bool
    let satellite: Bool
    var day = false

    static func camera(from start: MKMapCamera, to end: MKMapCamera, progress: Double) -> MKMapCamera {
        let t = min(1, max(0, progress))
        let eased = t * t * t * (t * (t * 6 - 15) + 10)
        let origin = GeoPoint(latitude: start.centerCoordinate.latitude, longitude: start.centerCoordinate.longitude)
        let destination = GeoPoint(latitude: end.centerCoordinate.latitude, longitude: end.centerCoordinate.longitude)
        let center = origin.interpolated(to: destination, fraction: eased)
        // Equal ratios of scale per frame avoid the abrupt end of a linear altitude animation.
        let distance = exp(log(max(1, start.centerCoordinateDistance)) * (1 - eased)
                           + log(max(1, end.centerCoordinateDistance)) * eased)
        let turn = (end.heading - start.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        return MKMapCamera(lookingAtCenter: center.coordinate, fromDistance: distance,
                           pitch: start.pitch + (end.pitch - start.pitch) * eased,
                           heading: start.heading + turn * eased)
    }
}

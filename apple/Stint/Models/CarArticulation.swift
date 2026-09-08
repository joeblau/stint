import Foundation
import CoreLocation

struct CarArticulation {
    /// Wheel yaw in the model's coordinates (+X right, -Z forward).
    let frontLeft: Double
    let frontRight: Double
    let drsOpen: Bool

    static let wheelbase = 2.85
    static let trackWidth = 1.86
    static let maximumSteering = 35.0 * .pi / 180

    static func estimate(recording: DriverRecording, at time: Double) -> Self {
        let before = recording.position(at: time - 0.18)
        let after = recording.position(at: time + 0.18)
        let distance = CLLocation(latitude: before.point.latitude, longitude: before.point.longitude)
            .distance(from: CLLocation(latitude: after.point.latitude, longitude: after.point.longitude))
        let turn = (after.heading - before.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        let limit = tan(maximumSteering) / wheelbase
        let curvature = distance > 0.05 ? min(limit, max(-limit, turn * .pi / 180 / distance)) : 0
        // Ackermann steering: the inside wheel follows a tighter turning radius.
        let left = atan(wheelbase * curvature / (1 + trackWidth * curvature / 2))
        let right = atan(wheelbase * curvature / (1 - trackWidth * curvature / 2))
        let drs = recording.position(at: time).drs
            ?? TelemetryEstimator.estimate(recording: recording, at: time).drs
        return Self(frontLeft: -min(maximumSteering, max(-maximumSteering, left)),
                    frontRight: -min(maximumSteering, max(-maximumSteering, right)), drsOpen: drs)
    }
}

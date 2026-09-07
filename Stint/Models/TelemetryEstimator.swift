import Foundation
import CoreLocation

struct Telemetry {
    var speedKPH: Double?
    var gear: Int?
    var rpm: Int?
    var throttle: Double
    var brake: Double
    var drs: Bool
}

enum TelemetryEstimator {
    private static let gearBands: [Double] = [0, 70, 105, 140, 175, 215, 255, 300]

    static func estimate(recording: DriverRecording, at time: Double) -> Telemetry {
        let speed = speedKPH(recording: recording, at: time)
        let acceleration = self.acceleration(recording: recording, at: time)
        var telemetry = Telemetry(speedKPH: speed, gear: nil, rpm: nil,
                                  throttle: 0, brake: 0, drs: false)
        if acceleration > 0.4 {
            telemetry.throttle = min(1, acceleration / 6)
        } else if acceleration < -0.4 {
            telemetry.brake = min(1, -acceleration / 8)
        }
        let position = recording.position(at: time)
        telemetry.throttle = position.throttle ?? telemetry.throttle
        telemetry.brake = position.brake ?? telemetry.brake
        if let speed {
            let gear = self.gear(for: speed)
            telemetry.gear = gear
            telemetry.rpm = rpm(for: speed, gear: gear)
            telemetry.drs = telemetry.throttle > 0.98 && speed > 260
        }
        telemetry.drs = position.drs ?? telemetry.drs
        return telemetry
    }

    static func gear(for speedKPH: Double) -> Int {
        var gear = 1
        for band in gearBands.dropFirst() where speedKPH >= band { gear += 1 }
        return min(gear, 8)
    }

    static func rpm(for speedKPH: Double, gear: Int) -> Int {
        guard speedKPH > 1 else { return 4000 }
        let lower = gearBands[max(0, gear - 1)]
        let upper = gear >= gearBands.count ? 360 : gearBands[gear]
        let fraction = min(1, max(0, (speedKPH - lower) / (upper - lower)))
        return Int((9500 + fraction * 3000).rounded()).clamped(to: 4000...13000)
    }

    private static func speedKPH(recording: DriverRecording, at time: Double) -> Double? {
        let position = recording.position(at: time)
        if let speed = position.speedKPH { return speed }
        // Replays may omit speed; derive it from ground distance over a short window.
        let window = 0.4
        let a = recording.position(at: time - window).point
        let b = recording.position(at: time + window).point
        let seconds = min(time + window, recording.samples.last?.time ?? time) - max(time - window, 0)
        guard seconds > 0 else { return nil }
        let meters = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        return meters / seconds * 3.6
    }

    private static func acceleration(recording: DriverRecording, at time: Double) -> Double {
        let window = 0.6
        guard let before = speedKPH(recording: recording, at: time - window),
              let after = speedKPH(recording: recording, at: time + window) else { return 0 }
        return (after - before) / 3.6 / (2 * window)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

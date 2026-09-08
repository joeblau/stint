import Foundation
import CoreLocation
import simd

/// One leg of the private jet's trip between two venues, time-compressed so that one second of
/// animation is one real hour of flight at Gulfstream G650 cruise (about 900 km/h), with a
/// three-second minimum for visible short hops. The path is the
/// great circle on the unit sphere; altitude is a smooth climb, cruise, and descent.
struct GlobeFlight {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D
    let fromVector: SIMD3<Double>
    let toVector: SIMD3<Double>
    let angleRadians: Double

    static let earthRadiusKm = 6_371.0
    static let cruiseKPH = 900.0
    /// Animation seconds per hour of flight.
    static let secondsPerHour = 1.0

    init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        self.from = from
        self.to = to
        fromVector = Self.vector(from)
        toVector = Self.vector(to)
        angleRadians = acos(min(1, max(-1, simd_dot(fromVector, toVector))))
    }

    var distanceKm: Double { angleRadians * Self.earthRadiusKm }
    var hours: Double { distanceKm / Self.cruiseKPH }
    var durationSeconds: Double { distanceKm < 0.001 ? 0 : max(3, hours * Self.secondsPerHour) }

    static func vector(_ coordinate: CLLocationCoordinate2D) -> SIMD3<Double> {
        let phi = coordinate.latitude * .pi / 180
        let lambda = coordinate.longitude * .pi / 180
        return SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }

    /// Spherical interpolation along the great circle at `progress` (0...1).
    func coordinate(at progress: Double) -> CLLocationCoordinate2D {
        let t = min(1, max(0, progress))
        guard angleRadians > 0.000_001 else { return from }
        let sine = sin(angleRadians)
        let a = sin((1 - t) * angleRadians) / sine
        let b = sin(t * angleRadians) / sine
        let v = fromVector * a + toVector * b
        return CLLocationCoordinate2D(latitude: asin(min(1, max(-1, v.z))) * 180 / .pi,
                                      longitude: atan2(v.y, v.x) * 180 / .pi)
    }

    /// A geographic prefix of the flight, including its exact current coordinate.
    /// Screen-space stroke percentages cannot represent progress on a projected globe.
    func coordinates(through progress: Double = 1) -> [CLLocationCoordinate2D] {
        let end = min(1, max(0, progress))
        let segments = max(1, Int(ceil(angleRadians * end / (.pi / 720))))
        return (0...segments).map { coordinate(at: end * Double($0) / Double(segments)) }
    }

    /// Altitude as a fraction of cruise height: smooth takeoff, level middle, smooth landing.
    func altitudeProfile(at progress: Double) -> Double {
        let t = min(1, max(0, progress))
        return sin(t * .pi)
    }

    /// "1 h 14 min" style label for the leg.
    var durationLabel: String {
        let minutes = Int((hours * 60).rounded())
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }
}

/// A trip along the calendar's route lines: one leg per pair of adjacent rounds between the
/// origin and the destination, flown in calendar order or in reverse. Wall time is the sum of
/// the legs, so a trip across several rounds takes as long as flying them one by one.
struct GlobeItinerary {
    let legs: [GlobeFlight]
    /// Rounds visited in order, origin first, when the trip follows the calendar.
    let rounds: [Int]

    var durationSeconds: Double { legs.reduce(0) { $0 + $1.durationSeconds } }
    var distanceKm: Double { legs.reduce(0) { $0 + $1.distanceKm } }
    var isEmpty: Bool { legs.isEmpty }

    /// The legs of the calendar route between two rounds, through every round in between.
    static func alongCalendar(from origin: SeasonRace, to destination: SeasonRace,
                              races: [SeasonRace] = Season2026.races) -> GlobeItinerary {
        guard let start = races.firstIndex(where: { $0.id == origin.id }),
              let end = races.firstIndex(where: { $0.id == destination.id }), start != end else {
            return GlobeItinerary(legs: [], rounds: [origin.id])
        }
        let step = end > start ? 1 : -1
        var legs: [GlobeFlight] = []
        var rounds = [origin.id]
        var index = start
        while index != end {
            let a = races[index]
            let b = races[index + step]
            legs.append(GlobeFlight(from: a.point.coordinate, to: b.point.coordinate))
            rounds.append(b.id)
            index += step
        }
        return GlobeItinerary(legs: legs, rounds: rounds)
    }

    /// A single direct leg, used when a trip is redirected mid-air.
    static func direct(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> GlobeItinerary {
        GlobeItinerary(legs: [GlobeFlight(from: from, to: to)], rounds: [])
    }

    struct Position {
        let coordinate: CLLocationCoordinate2D
        /// A point slightly further along the path, for heading.
        let ahead: CLLocationCoordinate2D
        let heading: Double
        let altitude: Double
        let legIndex: Int
        /// Distance progress along the current leg, 0...1.
        let legProgress: Double
        /// Overall wall-time progress, 0...1.
        let progress: Double
    }

    /// Constant ground speed on each geodesic; only altitude changes for takeoff/landing.
    /// Short legs take at least three seconds so adjacent European venues are visible.
    func position(at seconds: Double) -> Position? {
        guard !legs.isEmpty else { return nil }
        let total = durationSeconds
        let elapsed = min(max(0, seconds), total)
        var start = 0.0
        for (index, leg) in legs.enumerated() {
            let end = start + leg.durationSeconds
            if elapsed <= end || index == legs.count - 1 {
                let raw = leg.durationSeconds > 0 ? min(1, max(0, (elapsed - start) / leg.durationSeconds)) : 1
                let t = raw
                let before = leg.coordinate(at: max(0, t - 0.001))
                let after = leg.coordinate(at: min(1, t + 0.001))
                let heading = GeoPoint(latitude: before.latitude, longitude: before.longitude)
                    .bearing(to: GeoPoint(latitude: after.latitude, longitude: after.longitude))
                return Position(coordinate: leg.coordinate(at: t), ahead: after, heading: heading,
                                altitude: leg.altitudeProfile(at: t), legIndex: index, legProgress: t,
                                progress: total > 0 ? elapsed / total : 1)
            }
            start = end
        }
        return nil
    }
}

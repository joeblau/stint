import Foundation
import CoreLocation
import MapKit

struct GeoPoint: Codable, Equatable {
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var isValid: Bool {
        latitude.isFinite && longitude.isFinite && abs(latitude) <= 85 && abs(longitude) <= 180
    }

    func interpolated(to other: GeoPoint, fraction: Double) -> GeoPoint {
        let delta = (other.longitude - longitude + 540).truncatingRemainder(dividingBy: 360) - 180
        let lon = (longitude + delta * fraction + 540).truncatingRemainder(dividingBy: 360) - 180
        return GeoPoint(latitude: latitude + (other.latitude - latitude) * fraction, longitude: lon)
    }

    func bearing(to other: GeoPoint) -> Double {
        let a = latitude * .pi / 180
        let b = other.latitude * .pi / 180
        let delta = (other.longitude - longitude) * .pi / 180
        return (atan2(sin(delta) * cos(b), cos(a) * sin(b) - sin(a) * cos(b) * cos(delta)) * 180 / .pi + 360)
            .truncatingRemainder(dividingBy: 360)
    }

    func offset(meters: Double, bearing: Double) -> GeoPoint {
        let angle = bearing * .pi / 180
        return GeoPoint(latitude: latitude + meters * cos(angle) / 111_320,
                        longitude: longitude + meters * sin(angle) / (111_320 * cos(latitude * .pi / 180)))
    }
}

struct Driver: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let number: Int
    let color: String
    var team: String? = nil
}

struct PositionSample: Codable {
    let time: Double
    let latitude: Double
    let longitude: Double
    let heading: Double
    let speedKPH: Double?
    var racePosition: Int? = nil
    var gapToLeader: Double? = nil
    var throttle: Double? = nil
    var brake: Double? = nil
    var drs: Bool? = nil

    var point: GeoPoint { GeoPoint(latitude: latitude, longitude: longitude) }
}

struct DriverRecording: Codable {
    let driver: Driver
    let samples: [PositionSample]
    var gridPosition: Int? = nil
    var stints: [TyreStint]? = nil
    var pitStops: [PitStop]? = nil

    func position(at time: Double) -> CarPosition {
        // Validated recordings always contain at least two strictly ordered samples.
        var low = 0
        var high = samples.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if samples[mid].time <= time { low = mid } else { high = mid }
        }
        let a = samples[low]
        let b = samples[high]
        let fraction = min(1, max(0, (time - a.time) / (b.time - a.time)))
        let turn = (b.heading - a.heading + 540).truncatingRemainder(dividingBy: 360) - 180
        let heading = (a.heading + turn * fraction + 360).truncatingRemainder(dividingBy: 360)
        let speed: Double?
        if let first = a.speedKPH, let second = b.speedKPH {
            speed = first + (second - first) * fraction
        } else { speed = nil }
        let gap: Double?
        if let first = a.gapToLeader, let second = b.gapToLeader {
            gap = first + (second - first) * fraction
        } else { gap = nil }
        func pedal(_ first: Double?, _ second: Double?) -> Double? {
            if fraction == 0 { return first }
            if fraction == 1 { return second }
            guard let first, let second else { return nil }
            return first + (second - first) * fraction
        }
        return CarPosition(driver: driver, point: a.point.interpolated(to: b.point, fraction: fraction),
                           heading: heading, speedKPH: speed,
                           racePosition: fraction < 1 ? a.racePosition : b.racePosition, gapToLeader: gap,
                           throttle: pedal(a.throttle, b.throttle), brake: pedal(a.brake, b.brake),
                           drs: fraction < 1 ? a.drs : b.drs)
    }
}

struct CarPosition: Identifiable {
    let driver: Driver
    let point: GeoPoint
    let heading: Double
    let speedKPH: Double?
    var racePosition: Int? = nil
    var gapToLeader: Double? = nil
    var throttle: Double? = nil
    var brake: Double? = nil
    var drs: Bool? = nil
    var id: String { driver.id }
}

struct RaceReplay: Codable {
    let version: Int
    let title: String
    let circuit: [GeoPoint]
    let recordings: [DriverRecording]
    var totalLaps: Int? = nil

    var duration: Double { recordings.compactMap { $0.samples.last?.time }.max() ?? 0 }

    func validated() throws -> RaceReplay {
        guard version == 1 else { throw ReplayError.invalid("This replay version isn’t supported. Use version 1.") }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.count <= 120 else {
            throw ReplayError.invalid("Give the replay a title of 1–120 characters.")
        }
        guard (3...20_000).contains(circuit.count), circuit.allSatisfy(\.isValid) else {
            throw ReplayError.invalid("The circuit needs 3–20,000 valid latitude/longitude points (latitude ±85°).")
        }
        guard (1...24).contains(recordings.count), Set(recordings.map { $0.driver.id }).count == recordings.count else {
            throw ReplayError.invalid("Include 1–24 drivers with unique IDs.")
        }
        guard totalLaps.map({ (1...200).contains($0) }) ?? true else {
            throw ReplayError.invalid("totalLaps must be between 1 and 200.")
        }
        for recording in recordings {
            let driver = recording.driver
            guard !driver.id.isEmpty, driver.id.count <= 8, !driver.name.isEmpty, driver.name.count <= 80,
                  (0...999).contains(driver.number), driver.color.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) != nil else {
                throw ReplayError.invalid("Each driver needs a short ID, a name, a car number, and a #RRGGBB color.")
            }
            guard (2...200_000).contains(recording.samples.count), recording.samples.first?.time == 0 else {
                throw ReplayError.invalid("Each driver needs 2–200,000 samples, starting at time 0.")
            }
            guard recording.gridPosition.map({ (1...24).contains($0) }) ?? true else {
                throw ReplayError.invalid("Grid positions must be 1–24.")
            }
            let stints = recording.stints ?? []
            guard stints.allSatisfy({ $0.startLap >= 1 && ["S", "M", "H", "I", "W"].contains($0.compound) }),
                  zip(stints, stints.dropFirst()).allSatisfy({ $0.startLap < $1.startLap }) else {
                throw ReplayError.invalid("Tyre stints need increasing start laps and compounds S, M, H, I, or W.")
            }
            let stops = recording.pitStops ?? []
            guard stops.allSatisfy({ stop in
                      stop.lap >= 1 && stop.entryTime >= 0 && stop.exitTime > stop.entryTime && stop.exitTime <= 86_400
                          && (stop.stationary.map { $0 > 0 && $0 <= stop.exitTime - stop.entryTime } ?? true) }),
                  zip(stops, stops.dropFirst()).allSatisfy({ $0.exitTime <= $1.entryTime }) else {
                throw ReplayError.invalid("Pit stops need a lap, ordered entry/exit times, and a stationary time within the lane time.")
            }
            var previous = -Double.infinity
            for sample in recording.samples {
                guard sample.time.isFinite, sample.time > previous, sample.time <= 86_400, sample.point.isValid,
                      sample.heading.isFinite, (0..<360).contains(sample.heading),
                      sample.speedKPH.map({ $0.isFinite && (0...500).contains($0) }) ?? true else {
                    throw ReplayError.invalid("Samples need increasing times (up to 24 hours), valid coordinates, headings 0–359.999°, and speeds 0–500 km/h.")
                }
                guard sample.throttle.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
                      sample.brake.map({ $0.isFinite && (0...1).contains($0) }) ?? true else {
                    throw ReplayError.invalid("Throttle and brake must be fractions between 0 and 1.")
                }
                previous = sample.time
                guard sample.racePosition.map({ (1...24).contains($0) }) ?? true,
                      sample.gapToLeader.map({ $0.isFinite && (0...86_400).contains($0) }) ?? true else {
                    throw ReplayError.invalid("Standings need positions 1–24 and nonnegative gaps in seconds.")
                }
            }
        }
        return self
    }
}

enum ReplayError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

extension DemoCircuit {
    func load() throws -> RaceReplay {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "geojson") else {
            throw ReplayError.invalid("The bundled circuit is missing. Regenerate the Xcode project.")
        }
        let collection = try JSONDecoder().decode(CircuitCollection.self, from: Data(contentsOf: url))
        guard let line = collection.features.first?.geometry.coordinates, line.count >= 3,
              line.allSatisfy({ $0.count >= 2 }) else { throw ReplayError.invalid("Invalid circuit geometry.") }
        var points = line.map { GeoPoint(latitude: $0[1], longitude: $0[0]) }
        if points.first != points.last { points.append(points[0]) }
        let route = CircuitRoute.smoothed(points: points)
        let drivers = Grid2026.drivers
        let recordings = drivers.enumerated().map { index, driver in
            let speed = route.length / lapTime
            let samplesPerSecond = 30.0
            let samples = (0...Int(lapTime * 3 * samplesPerSecond)).map { tick -> PositionSample in
                let time = Double(tick) / samplesPerSecond
                let distance = time * speed + route.length * (1 - Double(index) * 0.026)
                let point = route.point(at: distance)
                let next = route.point(at: distance + 1)
                let previous = route.point(at: distance - 1)
                return PositionSample(time: time, latitude: point.latitude, longitude: point.longitude,
                                      heading: previous.bearing(to: next), speedKPH: speed * 3.6,
                                      racePosition: index + 1, gapToLeader: Double(index) * 0.026 * lapTime)
            }
            // Simulated tyre choices so the standings can show a compound and its age.
            let compound = ["M", "S", "H"][index % 3]
            return DriverRecording(driver: driver, samples: samples, gridPosition: index + 1,
                                   stints: [TyreStint(startLap: 1, compound: compound)])
        }
        return try RaceReplay(version: 1, title: title, circuit: route.points, recordings: recordings, totalLaps: 3).validated()
    }
}

private struct CircuitCollection: Decodable {
    struct Feature: Decodable {
        struct Geometry: Decodable { let coordinates: [[Double]] }
        let geometry: Geometry
    }
    let features: [Feature]
}

struct CircuitRoute {
    let points: [GeoPoint]
    let distances: [Double]
    let length: Double

    init(points: [GeoPoint]) {
        self.points = points
        var cumulative = [0.0]
        for index in 1..<points.count {
            let a = CLLocation(latitude: points[index - 1].latitude, longitude: points[index - 1].longitude)
            let b = CLLocation(latitude: points[index].latitude, longitude: points[index].longitude)
            cumulative.append(cumulative.last! + a.distance(from: b))
        }
        distances = cumulative
        length = cumulative.last ?? 0
    }

    func point(at distance: Double) -> GeoPoint {
        guard length > 0 else { return points[0] }
        let wrapped = (distance.truncatingRemainder(dividingBy: length) + length).truncatingRemainder(dividingBy: length)
        var low = 0
        var high = distances.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if distances[mid] <= wrapped { low = mid } else { high = mid }
        }
        let fraction = (wrapped - distances[low]) / max(0.0001, distances[high] - distances[low])
        return points[low].interpolated(to: points[high], fraction: fraction)
    }
}

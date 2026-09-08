import Foundation
import simd

/// Aligns OpenF1's arbitrary Cartesian coordinates to the bundled geographic circuit.
/// A complete non-pit lap supplies the shape; no latitude/longitude is invented from raw x/y.
struct OpenF1MapTransform {
    let origin: GeoPoint
    let sourceCenter: SIMD2<Double>
    let targetCenter: SIMD2<Double>
    let rotation: SIMD2<Double>
    let errorMeters: Double

    func point(_ source: SIMD2<Double>) -> GeoPoint {
        let p = source - sourceCenter
        let mapped = SIMD2(rotation.x * p.x - rotation.y * p.y, rotation.y * p.x + rotation.x * p.y) + targetCenter
        return GeoPoint(latitude: origin.latitude + mapped.y / 111_320,
                        longitude: origin.longitude + mapped.x / (111_320 * cos(origin.latitude * .pi / 180)))
    }

    static func fit(lap: [SIMD2<Double>], circuit: [GeoPoint]) throws -> Self {
        guard lap.count >= 20, circuit.count >= 3, lap.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ReplayError.invalid("OpenF1 has insufficient location data to align this circuit.")
        }
        let origin = circuit[0]
        let longitudeScale = 111_320 * cos(origin.latitude * .pi / 180)
        let target = circuit.map { SIMD2(($0.longitude - origin.longitude) * longitudeScale, ($0.latitude - origin.latitude) * 111_320) }
        let count = 256
        let source = try resample(lap, count: count)
        let destination = try resample(target, count: count)
        let sourceCenter = source.reduce(.zero, +) / Double(count)
        let targetCenter = destination.reduce(.zero, +) / Double(count)
        let a = source.map { $0 - sourceCenter }
        let b = destination.map { $0 - targetCenter }
        let denominator = a.reduce(0) { $0 + simd_length_squared($1) }
        guard denominator > 1 else { throw ReplayError.invalid("OpenF1 returned an empty circuit trace.") }
        var best: Self?
        // Geographic outlines can start anywhere and run in either direction.
        for direction in [1, -1] {
            for offset in 0..<count {
                var dot = 0.0, cross = 0.0
                for i in 0..<count {
                    let q = b[(offset + direction * i + count) % count]
                    dot += simd_dot(a[i], q)
                    cross += a[i].x * q.y - a[i].y * q.x
                }
                let rotation = SIMD2(dot, cross) / denominator
                var squaredError = 0.0
                for i in 0..<count {
                    let mapped = SIMD2(rotation.x * a[i].x - rotation.y * a[i].y, rotation.y * a[i].x + rotation.x * a[i].y)
                    squaredError += simd_length_squared(mapped - b[(offset + direction * i + count) % count])
                }
                let error = sqrt(squaredError / Double(count))
                if best == nil || error < best!.errorMeters {
                    best = Self(origin: origin, sourceCenter: sourceCenter, targetCenter: targetCenter, rotation: rotation, errorMeters: error)
                }
            }
        }
        guard let best, best.errorMeters < 50, simd_length(best.rotation) > 0.001 else {
            throw ReplayError.invalid("OpenF1’s circuit trace doesn’t match this map closely enough to replay. Try again when more complete data is available.")
        }
        return best
    }

    private static func resample(_ points: [SIMD2<Double>], count: Int) throws -> [SIMD2<Double>] {
        var closed = points
        if closed.last != closed.first { closed.append(closed[0]) }
        var distances = [0.0]
        for i in 1..<closed.count { distances.append(distances.last! + simd_distance(closed[i - 1], closed[i])) }
        guard let length = distances.last, length > 1 else { throw ReplayError.invalid("OpenF1 returned an empty circuit trace.") }
        var index = 0
        return (0..<count).map { sample in
            let distance = Double(sample) / Double(count) * length
            while index + 1 < distances.count - 1 && distances[index + 1] < distance { index += 1 }
            let fraction = (distance - distances[index]) / max(0.000001, distances[index + 1] - distances[index])
            return closed[index] + (closed[index + 1] - closed[index]) * fraction
        }
    }
}

enum OpenF1ReplayBuilder {
    static func validateCoverage(locations: [OpenF1.Location], laps: [OpenF1.Lap], driver: String) throws {
        let valid = locations.filter { $0.x.isFinite && $0.y.isFinite && ($0.x != 0 || $0.y != 0) }
        let starts = laps.compactMap(\.dateStart)
        let finishes = laps.compactMap { lap -> Date? in
            guard let start = lap.dateStart, let duration = lap.lapDuration, duration > 0 else { return nil }
            return start.addingTimeInterval(duration)
        }
        guard let expectedStart = starts.min(), let expectedEnd = finishes.max(),
              let first = valid.map(\.date).min(), let last = valid.map(\.date).max(),
              first <= expectedStart.addingTimeInterval(30), last >= expectedEnd.addingTimeInterval(-30) else {
            throw OpenF1DownloadError.incompleteLocations(driver)
        }
        let raceLocations = valid.filter { $0.date >= expectedStart && $0.date <= expectedEnd }.sorted { $0.date < $1.date }
        // Short feed gaps are interpolated. Long outages cannot be presented as a full race.
        guard zip(raceLocations, raceLocations.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) <= 60 }) else {
            throw OpenF1DownloadError.incompleteLocations(driver)
        }
    }

    static func transform(locations: [OpenF1.Location], laps: [OpenF1.Lap], circuit: [GeoPoint]) throws -> OpenF1MapTransform {
        for lap in laps.sorted(by: { ($0.lapDuration ?? .infinity) < ($1.lapDuration ?? .infinity) }) {
            guard lap.lapNumber > 1, lap.isPitOutLap != true, let start = lap.dateStart,
                  let duration = lap.lapDuration, duration > 20, duration < 300 else { continue }
            let end = start.addingTimeInterval(duration)
            let trace = locations.filter { $0.date >= start && $0.date <= end && ($0.x != 0 || $0.y != 0) }
            guard trace.count >= 40, let first = trace.first, let last = trace.last,
                  first.date.timeIntervalSince(start) < 2, end.timeIntervalSince(last.date) < 2,
                  zip(trace, trace.dropFirst()).allSatisfy({ $1.date.timeIntervalSince($0.date) < 5 }) else { continue }
            if let transform = try? OpenF1MapTransform.fit(lap: trace.map(\.vector), circuit: circuit) { return transform }
        }
        throw ReplayError.invalid("OpenF1 has no complete lap that can be aligned with this circuit map yet.")
    }

    static func recording(driver: Driver, locations: [OpenF1.Location], telemetry: [OpenF1.CarData],
                          positions: [OpenF1.Position], intervals: [OpenF1.Interval], stints: [OpenF1.Stint],
                          transform: OpenF1MapTransform, start: Date, end: Date) throws -> DriverRecording {
        let locations = locations.sorted { $0.date < $1.date }
        let telemetry = telemetry.sorted { $0.date < $1.date }
        let positions = positions.sorted { $0.date < $1.date }
        let intervals = intervals.sorted { $0.date < $1.date }
        var carIndex = 0, positionIndex = 0, intervalIndex = 0
        var samples: [PositionSample] = []
        for location in locations where location.date >= start && location.date <= end {
            guard location.x.isFinite, location.y.isFinite, location.x != 0 || location.y != 0 else { continue }
            let time = location.date.timeIntervalSince(start)
            guard time > (samples.last?.time ?? -1) else { continue }
            let car = latest(telemetry, index: &carIndex, at: location.date, date: { $0.date })
                .flatMap { location.date.timeIntervalSince($0.date) <= 2 ? $0 : nil }
            let position = latest(positions, index: &positionIndex, at: location.date, date: { $0.date })?.position
            let interval = latest(intervals, index: &intervalIndex, at: location.date, date: { $0.date })
            let gap = interval.flatMap { location.date.timeIntervalSince($0.date) <= 10 ? $0.gapToLeader?.seconds : nil }
            let point = transform.point(location.vector)
            guard point.isValid else { continue }
            samples.append(PositionSample(time: time, latitude: point.latitude, longitude: point.longitude, heading: 0,
                                          speedKPH: car?.speed.flatMap { (0...500).contains($0) ? $0 : nil },
                                          racePosition: position.flatMap { (1...24).contains($0) ? $0 : nil },
                                          gapToLeader: position == 1 ? 0 : gap.flatMap { (0...86_400).contains($0) ? $0 : nil },
                                          throttle: car?.throttle.map { min(1, max(0, $0 / 100)) },
                                          brake: car?.brake.map { min(1, max(0, $0 / 100)) },
                                          drs: car?.drs.map { [10, 12, 14].contains($0) },
                                          // Invalid optional channels must not invalidate the race replay.
                                          gear: car?.nGear.flatMap { (0...8).contains($0) ? $0 : nil },
                                          rpm: car?.rpm.flatMap { (0...25_000).contains($0) ? $0 : nil }))
        }
        guard samples.count >= 2 else { throw ReplayError.invalid("OpenF1 is missing location data for \(driver.name). No partial replay was saved.") }
        if samples[0].time > 0 {
            let first = samples[0]
            samples.insert(PositionSample(time: 0, latitude: first.latitude, longitude: first.longitude, heading: 0,
                                          speedKPH: nil), at: 0)
        }
        samples = samples.enumerated().map { index, sample in
            let before = samples[max(0, index - 1)].point
            let after = samples[min(samples.count - 1, index + 1)].point
            return PositionSample(time: sample.time, latitude: sample.latitude, longitude: sample.longitude,
                                  heading: before == after ? (index > 0 ? samples[index - 1].point.bearing(to: sample.point) : 0) : before.bearing(to: after),
                                  speedKPH: sample.speedKPH, racePosition: sample.racePosition, gapToLeader: sample.gapToLeader,
                                  throttle: sample.throttle, brake: sample.brake, drs: sample.drs, gear: sample.gear, rpm: sample.rpm)
        }
        var tyreStints: [Int: String] = [:]
        for stint in stints {
            guard let lap = stint.lapStart, lap >= 1, let compound = stint.compound,
                  let letter = ["SOFT": "S", "MEDIUM": "M", "HARD": "H", "INTERMEDIATE": "I", "WET": "W"][compound] else { continue }
            tyreStints[lap] = letter
        }
        return DriverRecording(driver: driver, samples: samples, gridPosition: positions.first?.position,
                               stints: tyreStints.sorted { $0.key < $1.key }.map { TyreStint(startLap: $0.key, compound: $0.value) })
    }

    private static func latest<T>(_ values: [T], index: inout Int, at date: Date, date timestamp: (T) -> Date) -> T? {
        guard !values.isEmpty else { return nil }
        while index + 1 < values.count && timestamp(values[index + 1]) <= date { index += 1 }
        return timestamp(values[index]) <= date ? values[index] : nil
    }
}

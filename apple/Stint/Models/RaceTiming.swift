import Foundation

/// A tyre set fitted from `startLap` onward. Compounds use the F1 letters S, M, H, I, W.
struct TyreStint: Codable, Equatable {
    let startLap: Int
    let compound: String
}

/// One visit to the pit lane. `stationary` is the stop itself when known; otherwise the lane time is shown.
struct PitStop: Codable, Equatable {
    let lap: Int
    let entryTime: Double
    let exitTime: Double
    var stationary: Double? = nil
}

/// Timing derived from replay positions. Replays only record where each car is, so laps are counted
/// as crossings of the start/finish line (the first circuit point), sectors split the lap into three
/// equal distances, and gaps compare when two cars reached the same track distance. Every value is
/// evaluated "as of" the replay time so scrubbing never reveals results from later in the race.
struct RaceTiming {
    struct Lap {
        let number: Int
        let end: Double
        let time: Double?          // nil when the lap started before the replay
        let sectors: [Double?]     // three sector times
    }

    struct SectorRecord {
        let time: Double           // when the sector was completed
        let index: Int             // 0...2
        let value: Double
    }

    struct DriverTiming {
        let progress: [(time: Double, distance: Double)]
        let laps: [Lap]
        let crossings: [(index: Int, time: Double)]   // every sector boundary, in order
        let sectorRecords: [SectorRecord]
        let bestLapPrefix: [Double]                     // min lap time among laps[0...i]
        let bestSectorPrefix: [[Double]]                // per sector, min among sectorRecords of that sector so far
        let gridPosition: Int?
        let stints: [TyreStint]
        let pitStops: [PitStop]

        func distance(at time: Double) -> Double {
            guard let first = progress.first else { return 0 }
            if time <= first.time { return first.distance }
            if let last = progress.last, time >= last.time { return last.distance }
            var low = 0
            var high = progress.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if progress[mid].time <= time { low = mid } else { high = mid }
            }
            let a = progress[low]
            let b = progress[high]
            let fraction = (time - a.time) / max(0.0001, b.time - a.time)
            return a.distance + (b.distance - a.distance) * fraction
        }

        /// When this car first reached `distance`, or nil if it never has.
        func time(reaching distance: Double) -> Double? {
            guard let first = progress.first, distance >= first.distance else { return nil }
            guard let last = progress.last, distance <= last.distance else { return nil }
            var low = 0
            var high = progress.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if progress[mid].distance <= distance { low = mid } else { high = mid }
            }
            let a = progress[low]
            let b = progress[high]
            let fraction = (distance - a.distance) / max(0.0001, b.distance - a.distance)
            return a.time + (b.time - a.time) * min(1, max(0, fraction))
        }

        func lapsCompleted(at time: Double) -> Int { laps.prefix { $0.end <= time }.count }
    }

    enum Gap: Equatable {
        case leader
        case time(Double)
        case laps(Int)
    }

    enum Highlight { case none, personalBest, sessionBest }

    struct Row {
        var lapsCompleted = 0
        var lastLap: Double?
        var lastLapHighlight = Highlight.none
        var bestLap: Double?
        var bestLapHighlight = Highlight.none
        var sectors: [(time: Double?, highlight: Highlight)] = Array(repeating: (nil, .none), count: 3)
        var gap: Gap?
        var interval: Gap?
        var tyre: (compound: String, age: Int)?
        var pit = PitState.none
        var diff: Int?

        enum PitState: Equatable {
            case none
            case inLane
            case out
            case stops(count: Int, last: Double)
        }
    }

    let length: Double
    let totalLaps: Int?
    let drivers: [String: DriverTiming]
    static let sectorCount = 3
    static let pitOutDuration = 45.0
    /// Times within this tolerance count as equal, so interpolation noise cannot turn a tie into a slower lap.
    static let tolerance = 0.01

    init(replay: RaceReplay) {
        let route = CircuitRoute(points: replay.circuit)
        length = route.length
        totalLaps = replay.totalLaps
        var drivers: [String: DriverTiming] = [:]
        for recording in replay.recordings {
            if Task.isCancelled { break }
            drivers[recording.driver.id] = Self.derive(recording, route: route)
        }
        self.drivers = drivers
    }

    private static func derive(_ recording: DriverRecording, route: CircuitRoute) -> DriverTiming {
        let length = route.length
        let sector = length / Double(sectorCount)
        var progress: [(time: Double, distance: Double)] = []
        progress.reserveCapacity(recording.samples.count)
        var lapIndex = 0
        var previousTrack: Double?
        var hint: Int?
        for sample in recording.samples {
            let projected = route.project(sample.point, hint: hint)
            hint = projected.index
            if let previousTrack {
                let delta = projected.distance - previousTrack
                if delta < -length / 2 { lapIndex += 1 } else if delta > length / 2 { lapIndex -= 1 }
            } else {
                // Cars on the grid sit just before the line; count them as still on the lap before.
                lapIndex = projected.distance > length / 2 ? -1 : 0
            }
            previousTrack = projected.distance
            progress.append((sample.time, Double(lapIndex) * length + projected.distance))
        }

        // Every sector boundary this car crossed, interpolated between the surrounding samples.
        var crossings: [(index: Int, time: Double)] = []
        guard length > 0, let first = progress.first else {
            return DriverTiming(progress: progress, laps: [], crossings: [], sectorRecords: [], bestLapPrefix: [],
                                bestSectorPrefix: [[], [], []], gridPosition: recording.gridPosition,
                                stints: recording.stints ?? [], pitStops: recording.pitStops ?? [])
        }
        var next = Int(ceil(first.distance / sector))
        if Double(next) * sector <= first.distance { next += 1 }
        for i in 1..<progress.count {
            let a = progress[i - 1]
            let b = progress[i]
            guard b.distance > a.distance else { continue }
            while Double(next) * sector <= b.distance {
                let boundary = Double(next) * sector
                let fraction = (boundary - a.distance) / (b.distance - a.distance)
                crossings.append((next, a.time + (b.time - a.time) * min(1, max(0, fraction))))
                next += 1
            }
        }

        var laps: [Lap] = []
        var records: [SectorRecord] = []
        var byIndex: [Int: Double] = [:]
        for crossing in crossings { byIndex[crossing.index] = crossing.time }
        for crossing in crossings {
            let sectorIndex = ((crossing.index % sectorCount) + sectorCount - 1) % sectorCount
            if let start = byIndex[crossing.index - 1] {
                records.append(SectorRecord(time: crossing.time, index: sectorIndex, value: crossing.time - start))
            }
            guard crossing.index % sectorCount == 0, crossing.index >= sectorCount else { continue }
            let sectors = (0..<sectorCount).map { offset -> Double? in
                let end = crossing.index - sectorCount + offset + 1
                guard let endTime = byIndex[end], let startTime = byIndex[end - 1] else { return nil }
                return endTime - startTime
            }
            let start = byIndex[crossing.index - sectorCount]
            laps.append(Lap(number: laps.count + 1, end: crossing.time, time: start.map { crossing.time - $0 }, sectors: sectors))
        }

        var bestLapPrefix: [Double] = []
        var runningBest = Double.infinity
        for lap in laps {
            runningBest = min(runningBest, lap.time ?? .infinity)
            bestLapPrefix.append(runningBest)
        }
        var bestSectorPrefix: [[Double]] = Array(repeating: [], count: sectorCount)
        var sectorBest = Array(repeating: Double.infinity, count: sectorCount)
        for record in records {
            sectorBest[record.index] = min(sectorBest[record.index], record.value)
            bestSectorPrefix[record.index].append(sectorBest[record.index])
        }
        return DriverTiming(progress: progress, laps: laps, crossings: crossings, sectorRecords: records,
                            bestLapPrefix: bestLapPrefix, bestSectorPrefix: bestSectorPrefix,
                            gridPosition: recording.gridPosition ?? recording.samples.first?.racePosition,
                            stints: recording.stints ?? [], pitStops: recording.pitStops ?? [])
    }

    /// Standings values for every car at `time`. `order` is the current classification, leader first.
    func rows(at time: Double, order: [CarPosition]) -> [String: Row] {
        // Session bests so far, so a purple sector or lap never leaks from later in the replay.
        var sessionBestLap = Double.infinity
        var sessionBestSectors = Array(repeating: Double.infinity, count: Self.sectorCount)
        for driver in drivers.values {
            let completed = driver.lapsCompleted(at: time)
            if completed > 0 { sessionBestLap = min(sessionBestLap, driver.bestLapPrefix[completed - 1]) }
            var counts = Array(repeating: 0, count: Self.sectorCount)
            for record in driver.sectorRecords where record.time <= time { counts[record.index] += 1 }
            for index in 0..<Self.sectorCount where counts[index] > 0 {
                sessionBestSectors[index] = min(sessionBestSectors[index], driver.bestSectorPrefix[index][counts[index] - 1])
            }
        }

        var rows: [String: Row] = [:]
        let leader = order.first.flatMap { drivers[$0.id] }
        for (position, car) in order.enumerated() {
            guard let driver = drivers[car.id] else { continue }
            var row = Row()
            let completed = driver.lapsCompleted(at: time)
            row.lapsCompleted = completed
            if completed > 0 {
                let lap = driver.laps[completed - 1]
                row.lastLap = lap.time
                let best = driver.bestLapPrefix[completed - 1]
                if let lapTime = lap.time {
                    row.lastLapHighlight = lapTime <= sessionBestLap + Self.tolerance ? .sessionBest
                        : (lapTime <= best + Self.tolerance ? .personalBest : .none)
                }
                if best.isFinite {
                    row.bestLap = best
                    row.bestLapHighlight = best <= sessionBestLap + Self.tolerance ? .sessionBest : .none
                }
            }

            // The latest value for each sector, whether from the lap in progress or the previous one.
            var counts = Array(repeating: 0, count: Self.sectorCount)
            var latest: [SectorRecord?] = Array(repeating: nil, count: Self.sectorCount)
            for record in driver.sectorRecords where record.time <= time {
                counts[record.index] += 1
                latest[record.index] = record
            }
            for index in 0..<Self.sectorCount {
                guard let record = latest[index] else { continue }
                let personalBest = driver.bestSectorPrefix[index][counts[index] - 1]
                let highlight: Highlight = record.value <= sessionBestSectors[index] + Self.tolerance ? .sessionBest
                    : (record.value <= personalBest + Self.tolerance ? .personalBest : .none)
                row.sectors[index] = (record.value, highlight)
            }

            if position == 0 {
                row.gap = .leader
            } else if let provided = car.gapToLeader {
                row.gap = .time(provided)
            } else if let leader {
                row.gap = timeBehind(leader, driver, at: time)
            }
            if position > 0 {
                let ahead = order[position - 1]
                if let mine = car.gapToLeader, let theirs = ahead.gapToLeader {
                    row.interval = .time(max(0, mine - theirs))
                } else if let aheadTiming = drivers[ahead.id] {
                    row.interval = timeBehind(aheadTiming, driver, at: time)
                }
            }

            let currentLap = completed + 1
            if let stint = driver.stints.last(where: { $0.startLap <= currentLap }) {
                row.tyre = (stint.compound, currentLap - stint.startLap + 1)
            }

            let stops = driver.pitStops.filter { $0.entryTime <= time }
            if let last = stops.last {
                if last.exitTime > time { row.pit = .inLane }
                else if time - last.exitTime < Self.pitOutDuration { row.pit = .out }
                else { row.pit = .stops(count: stops.count, last: last.stationary ?? (last.exitTime - last.entryTime)) }
            }

            if let grid = driver.gridPosition, let current = car.racePosition { row.diff = grid - current }
            rows[car.id] = row
        }
        return rows
    }

    /// How far behind `reference` the `driver` is at `time`: the time since the reference car passed
    /// the driver's current track distance, or whole laps when more than a lap behind.
    private func timeBehind(_ reference: DriverTiming, _ driver: DriverTiming, at time: Double) -> Gap? {
        guard length > 0 else { return nil }
        let mine = driver.distance(at: time)
        let theirs = reference.distance(at: time)
        if theirs - mine >= length { return .laps(Int((theirs - mine) / length)) }
        guard let passed = reference.time(reaching: mine) else { return nil }
        return .time(max(0, time - passed))
    }

    static func lapString(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let remainder = seconds - Double(minutes) * 60
        return minutes > 0 ? String(format: "%d:%06.3f", minutes, remainder) : String(format: "%.3f", remainder)
    }
}

extension CircuitRoute {
    /// The distance along the route of the point nearest to `point`. `hint` limits the search to
    /// segments near the previous match; a full search runs when the match is poor.
    func project(_ point: GeoPoint, hint: Int?, window: Int = 40) -> (distance: Double, index: Int) {
        let segments = points.count - 1
        guard segments > 0 else { return (0, 0) }
        let scale = cos(point.latitude * .pi / 180) * 111_320
        func local(_ p: GeoPoint) -> (x: Double, y: Double) {
            ((p.longitude - point.longitude) * scale, (p.latitude - point.latitude) * 111_320)
        }
        var best = (squared: Double.infinity, distance: 0.0, index: 0)
        func consider(_ i: Int) {
            let a = local(points[i])
            let b = local(points[i + 1])
            let dx = b.x - a.x
            let dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(1, max(0, -(a.x * dx + a.y * dy) / lengthSquared)) : 0
            let px = a.x + dx * t
            let py = a.y + dy * t
            let squared = px * px + py * py
            if squared < best.squared { best = (squared, distances[i] + sqrt(lengthSquared) * t, i) }
        }
        if let hint {
            for offset in -window...window { consider(((hint + offset) % segments + segments) % segments) }
            if best.squared < 60 * 60 { return (best.distance, best.index) }
        }
        for i in 0..<segments { consider(i) }
        return (best.distance, best.index)
    }
}

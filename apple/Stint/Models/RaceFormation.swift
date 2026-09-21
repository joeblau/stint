import Foundation

/// Playback-only side-by-side placement. Public position feeds cannot resolve which side of the
/// track a car is on: two cars within a few meters of each other along the lap are recorded on the
/// same line, so a replay draws them on top of one another. This index keeps the recorded track
/// distance as the only longitudinal authority and infers a synthetic lateral offset, perpendicular
/// to the car's heading, that is nonzero only while cars are close enough to overlap.
///
/// Sides are decided once when a pair closes up and kept until the cars separate: a pair that met
/// within the last twenty seconds keeps its previous sides; otherwise the attacking car (the one
/// behind) takes the inside of the next corner. Lane changes ease over 0.9 seconds and the offset
/// scales with how much the cars overlap, so placement is continuous in time and deterministic when
/// seeking. Cars on different roads (pit lane beside the track) are never separated. Saved
/// coordinates, timestamps, telemetry, and timing are unchanged.
struct RaceFormation {
    /// Distance between neighboring lanes. A pair sits at ±1 m; three abreast at −2, 0, +2 m.
    static let laneWidth = 2.0
    /// Cars closer than this along the track must take distinct lanes; they release a little later.
    /// Nose-to-tail cars in a train are further apart than this and can share a lane.
    static let conflictDistance = 9.0
    static let releaseDistance = 12.0
    /// The offset is full when cars overlap by more than a car length and fades to zero by `separationDistance`.
    static let fullOverlapDistance = 6.0
    static let separationDistance = 14.0
    /// Recorded positions further apart than this across the track are on different roads (pit lane
    /// beside the track); the placement fades out by `differentRoadTolerance` rather than switching.
    static let sameRoadTolerance = 5.0
    static let differentRoadTolerance = 8.0
    /// A pair that met this recently keeps its previous sides.
    static let memoryDuration = 20.0
    static let laneTransition = 0.9
    /// Widest offset in lanes; wider groups are squeezed to fit.
    static let maxLane = 2.0
    private static let step = 0.25
    private static let cornerLookahead = 800.0
    private static let cornerWindow = 60.0
    private static let cornerThreshold = 20.0

    struct LaneChange: Equatable {
        let time: Double
        let from: Double
        let to: Double
    }

    private let drivers: [RaceTiming.DriverTiming?]
    private let indexByDriver: [String: Int]
    private let lanes: [[LaneChange]]
    private let length: Double

    init(replay: RaceReplay, timing: RaceTiming) {
        let route = CircuitRoute(points: replay.circuit)
        let turns = TurnProfile(route: route)
        let count = replay.recordings.count
        let drivers = replay.recordings.map { timing.drivers[$0.driver.id] }
        self.drivers = drivers
        indexByDriver = Dictionary(uniqueKeysWithValues: replay.recordings.enumerated().map { ($1.driver.id, $0) })
        length = route.length
        // Circuit outlines can run against the direction of travel; progress tells which way the race goes.
        let travelled = drivers.reduce(0.0) { total, driver in
            guard let first = driver?.progress.first, let last = driver?.progress.last else { return total }
            return total + last.distance - first.distance
        }
        let direction: Double = travelled >= 0 ? 1 : -1
        var simulation = Simulation(count: count, length: route.length, direction: direction, turns: turns)
        var time = 0.0
        let duration = replay.duration
        var distances = [Double](repeating: .nan, count: count)
        var laterals = [Double](repeating: .nan, count: count)
        while time <= duration, route.length > 0 {
            if Task.isCancelled { break }
            for (index, driver) in drivers.enumerated() {
                distances[index] = driver?.distance(at: time) ?? Double.nan
                laterals[index] = driver?.lateral(at: time) ?? Double.nan
            }
            simulation.advance(to: time, distances: distances, laterals: laterals)
            time += Self.step
        }
        lanes = simulation.lanes
    }

    /// Applies inferred lateral offsets and lap distances to raw positions at `time`.
    func place(_ positions: [CarPosition], at time: Double) -> [CarPosition] {
        guard positions.count > 1, length > 0 else { return positions }
        let count = positions.count
        var index = [Int](repeating: -1, count: count)
        var distance = [Double](repeating: .nan, count: count)
        var lateral = [Double](repeating: .nan, count: count)
        for (k, position) in positions.enumerated() {
            guard let i = indexByDriver[position.id], let driver = drivers[i] else { continue }
            index[k] = i
            distance[k] = driver.distance(at: time)
            lateral[k] = driver.lateral(at: time)
        }
        var weight = [Double](repeating: 0, count: count)
        for i in 0..<count where distance[i].isFinite {
            for j in (i + 1)..<count where distance[j].isFinite {
                let road = Self.sameRoad(across: abs(lateral[i] - lateral[j]))
                guard road > 0 else { continue }
                let overlap = Self.overlap(gap: abs(Self.wrapped(distance[i] - distance[j], length: length))) * road
                guard overlap > 0 else { continue }
                weight[i] = max(weight[i], overlap)
                weight[j] = max(weight[j], overlap)
            }
        }
        return positions.enumerated().map { k, position in
            guard index[k] >= 0, distance[k].isFinite else { return position }
            var placed = position
            let lap = distance[k].truncatingRemainder(dividingBy: length)
            placed.trackDistance = lap < 0 ? lap + length : lap
            placed.lateralOffset = Self.lane(lanes[index[k]], at: time) * Self.laneWidth * weight[k]
            return placed
        }
    }

    /// How much two cars overlap: 1 within a car length, fading to 0 as they separate.
    static func overlap(gap: Double) -> Double {
        smoothstep((separationDistance - gap) / (separationDistance - fullOverlapDistance))
    }

    /// Whether two recorded positions `across` meters apart share a road: 1 within
    /// `sameRoadTolerance`, fading to 0 at `differentRoadTolerance`.
    static func sameRoad(across: Double) -> Double {
        smoothstep((differentRoadTolerance - across) / (differentRoadTolerance - sameRoadTolerance))
    }

    /// The eased lane at `time` from a car's recorded lane changes.
    static func lane(_ changes: [LaneChange], at time: Double) -> Double {
        var low = -1, high = changes.count
        while low + 1 < high {
            let mid = (low + high) / 2
            if changes[mid].time <= time { low = mid } else { high = mid }
        }
        guard low >= 0 else { return 0 }
        let change = changes[low]
        return change.from + (change.to - change.from) * smoothstep((time - change.time) / laneTransition)
    }

    static func wrapped(_ delta: Double, length: Double) -> Double {
        guard delta.isFinite, length > 0 else { return .nan }
        var wrapped = delta.truncatingRemainder(dividingBy: length)
        if wrapped > length / 2 { wrapped -= length } else if wrapped <= -length / 2 { wrapped += length }
        return wrapped
    }

    private static func smoothstep(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x * x * (3 - 2 * x)
    }

    /// Signed heading change accumulated along the circuit, for finding the next corner.
    private struct TurnProfile {
        let distances: [Double]
        let cumulative: [Double]
        let length: Double

        init(route: CircuitRoute) {
            distances = route.distances
            length = route.length
            let points = route.points
            let segments = points.count - 1
            var headings: [Double] = []
            for k in 0..<max(0, segments) {
                if route.distances[k + 1] > route.distances[k] {
                    headings.append(points[k].bearing(to: points[k + 1]))
                } else {
                    headings.append(headings.last ?? 0)
                }
            }
            var cumulative = [0.0]
            for k in 0..<max(0, segments) {
                let next = headings[(k + 1) % segments]
                let turn = (next - headings[k] + 540).truncatingRemainder(dividingBy: 360) - 180
                cumulative.append(cumulative[k] + turn)
            }
            self.cumulative = cumulative
        }

        /// Cumulative turn at route distance `distance`, continuing across laps.
        func turn(at distance: Double) -> Double {
            guard length > 0, cumulative.count > 1 else { return 0 }
            let laps = floor(distance / length)
            let wrapped = distance - laps * length
            var low = 0, high = distances.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if distances[mid] <= wrapped { low = mid } else { high = mid }
            }
            let span = distances[high] - distances[low]
            let fraction = span > 0 ? (wrapped - distances[low]) / span : 0
            return laps * cumulative[cumulative.count - 1] + cumulative[low] + (cumulative[high] - cumulative[low]) * fraction
        }

        /// +1 when the next corner turns right, −1 when left, 0 when no corner is within the lookahead.
        func upcomingCorner(from distance: Double, direction: Double) -> Int {
            var ahead = 0.0
            while ahead < RaceFormation.cornerLookahead {
                let start = turn(at: distance + direction * ahead)
                let end = turn(at: distance + direction * (ahead + RaceFormation.cornerWindow))
                let delta = end - start
                if abs(delta) >= RaceFormation.cornerThreshold { return delta > 0 ? 1 : -1 }
                ahead += 10
            }
            return 0
        }
    }

    /// The offline pass: tracks which pairs are close, assigns lanes within each group of
    /// touching cars, and records every lane change so playback can look them up at any time.
    private struct Simulation {
        let count: Int
        let length: Double
        let direction: Double
        let turns: TurnProfile
        var slots: [Int?]
        var current: [Double]
        var lanes: [[LaneChange]]
        var conflicts = Set<Int>()
        /// Side of the lower-index car relative to the higher-index car when they last separated.
        var lastSides: [Int: (end: Double, side: Int)] = [:]
        var time = 0.0
        var distances: [Double] = []

        init(count: Int, length: Double, direction: Double, turns: TurnProfile) {
            self.count = count
            self.length = length
            self.direction = direction
            self.turns = turns
            slots = Array(repeating: nil, count: count)
            current = Array(repeating: 0, count: count)
            lanes = Array(repeating: [], count: count)
        }

        func key(_ a: Int, _ b: Int) -> Int { min(a, b) * count + max(a, b) }

        mutating func advance(to time: Double, distances: [Double], laterals: [Double]) {
            self.time = time
            self.distances = distances
            var affected = Set<Int>()
            for i in 0..<count {
                for j in (i + 1)..<count {
                    let pair = key(i, j)
                    let gap = RaceFormation.wrapped(distances[i] - distances[j], length: length)
                    let across = abs(laterals[i] - laterals[j])
                    if conflicts.contains(pair) {
                        guard !(gap.isFinite && abs(gap) <= RaceFormation.releaseDistance
                                && across <= RaceFormation.differentRoadTolerance) else { continue }
                        conflicts.remove(pair)
                        if let a = slots[i], let b = slots[j], a != b { lastSides[pair] = (time, a > b ? 1 : -1) }
                        affected.insert(i)
                        affected.insert(j)
                    } else if gap.isFinite, abs(gap) < RaceFormation.conflictDistance, across < RaceFormation.sameRoadTolerance {
                        conflicts.insert(pair)
                        affected.insert(i)
                        affected.insert(j)
                    }
                }
            }
            guard !affected.isEmpty else { return }
            var visited = Set<Int>()
            for start in affected.sorted() where !visited.contains(start) {
                var component = [start]
                var queue = [start]
                visited.insert(start)
                while let car = queue.popLast() {
                    for other in 0..<count where !visited.contains(other) && conflicts.contains(key(car, other)) {
                        visited.insert(other)
                        component.append(other)
                        queue.append(other)
                    }
                }
                if component.count == 1 {
                    slots[start] = nil
                    setLane(start, 0)
                } else {
                    assign(component)
                }
            }
        }

        private func ahead(_ car: Int, of other: Int) -> Double {
            RaceFormation.wrapped(distances[car] - distances[other], length: length) * direction
        }

        private mutating func assign(_ component: [Int]) {
            // Cars already in formation keep their lane when they can; leaders settle first.
            let order = component.sorted { a, b in
                let placedA = slots[a] != nil, placedB = slots[b] != nil
                if placedA != placedB { return placedA }
                let aheadA = distances[a] * direction, aheadB = distances[b] * direction
                if aheadA != aheadB { return aheadA > aheadB }
                return a < b
            }
            var placed: [Int: Int] = [:]
            for car in order {
                let partners = component.filter { $0 != car && placed[$0] != nil && conflicts.contains(key(car, $0)) }
                let taken = Set(partners.map { placed[$0]! })
                if partners.isEmpty { placed[car] = slots[car] ?? 0; continue }
                if let existing = slots[car], !taken.contains(existing) { placed[car] = existing; continue }
                let anchor = partners.min { abs(ahead(car, of: $0)) < abs(ahead(car, of: $1)) }!
                let anchorSlot = placed[anchor]!
                let preferred = preferredSide(of: car, relativeTo: anchor)
                let range = placed.values.min()!...placed.values.max()!
                func preservesSides(_ candidate: Int) -> Bool {
                    guard let mine = slots[car] else { return true }
                    return partners.allSatisfy { partner in
                        guard let theirs = slots[partner] else { return true }
                        return (candidate - placed[partner]!).signum() == (mine - theirs).signum()
                    }
                }
                var chosen: Int?
                var fallback: Int?
                var step = 1
                while chosen == nil, step <= count + 1 {
                    let near = anchorSlot + preferred * step, far = anchorSlot - preferred * step
                    let candidates: [Int]
                    if !taken.contains(near), !taken.contains(far) {
                        // Prefer the side the rules ask for, unless only it would widen the group.
                        let widensNear = !range.contains(near), widensFar = !range.contains(far)
                        candidates = widensNear && !widensFar ? [far, near] : [near, far]
                    } else {
                        candidates = [near, far].filter { !taken.contains($0) }
                    }
                    for candidate in candidates {
                        if fallback == nil { fallback = candidate }
                        if preservesSides(candidate) { chosen = candidate; break }
                    }
                    step += 1
                }
                placed[car] = chosen ?? fallback ?? anchorSlot + preferred
            }
            // Center the group on the track; a group wider than the track squeezes rather than
            // clamps, so no two touching cars share an edge lane.
            let ranks = Set(placed.values).sorted()
            let center = Double(ranks.count - 1) / 2
            let scale = center > RaceFormation.maxLane ? RaceFormation.maxLane / center : 1
            for (car, slot) in placed {
                let rank = ranks.firstIndex(of: slot)!
                slots[car] = rank
                setLane(car, (Double(rank) - center) * scale)
            }
        }

        /// +1 when `car` should run to the right of `anchor`.
        private func preferredSide(of car: Int, relativeTo anchor: Int) -> Int {
            let pair = key(car, anchor)
            if let last = lastSides[pair], time - last.end < RaceFormation.memoryDuration {
                return car < anchor ? last.side : -last.side
            }
            let gap = ahead(car, of: anchor)
            let leader = gap > 0 ? car : anchor
            let lap = distances[leader].truncatingRemainder(dividingBy: length)
            let inside = turns.upcomingCorner(from: lap < 0 ? lap + length : lap, direction: direction)
            if inside != 0 { return gap > 0 ? -inside : inside }
            return car < anchor ? 1 : -1
        }

        private mutating func setLane(_ car: Int, _ lane: Double) {
            guard current[car] != lane else { return }
            let from = RaceFormation.lane(lanes[car], at: time)
            lanes[car].append(LaneChange(time: time, from: from, to: lane))
            current[car] = lane
        }
    }
}

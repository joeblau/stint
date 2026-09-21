import XCTest
@testable import Stint

/// Checks the side-by-side inference against the saved Monza download when it is present.
final class RaceFormationReplayTests: XCTestCase {
    private static let replayURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("races/2026-09-06-monza.json")

    func testRealReplayKeepsOverlappingCarsApartWithoutJumps() throws {
        guard let data = try? Data(contentsOf: Self.replayURL) else { throw XCTSkip("No saved Monza replay.") }
        let replay = try JSONDecoder().decode(RaceReplay.self, from: data).validated()
        let prepared = RaceReplay(version: 1, title: replay.title, circuit: replay.circuit,
                                  recordings: replay.recordings.map { $0.preparingMotion() },
                                  totalLaps: replay.totalLaps, startDate: replay.startDate)
        let timingStart = Date()
        let timing = RaceTiming(replay: replay)
        let timingSeconds = Date().timeIntervalSince(timingStart)
        let formationStart = Date()
        let formation = RaceFormation(replay: replay, timing: timing)
        let formationSeconds = Date().timeIntervalSince(formationStart)

        let route = CircuitRoute(points: replay.circuit)
        var overlapping = 0, separated = 0, maxJump = 0.0, placements = 0
        var jumpTime = 0.0, jumpID = ""
        var failuresByWindow: [Int: Int] = [:], overlapsByWindow: [Int: Int] = [:]
        var bothCentered = 0, sameSide = 0, clusterSizes: [Int: Int] = [:]
        var closeSince: [String: Double] = [:], sustained = 0
        var previous: [String: Double] = [:], previousDistance: [String: Double] = [:]
        var time = 0.0
        let placeStart = Date()
        // The opening 25 minutes hold the start, the first pit window, and most of the battles.
        while time < min(replay.duration, 1500) {
            let positions = formation.place(prepared.recordings.map { $0.position(at: time) }, at: time)
            placements += 1
            // The 1 Hz feed teleports cars and freezes others around the start; judge continuity only
            // where a car closes on every nearby car at a plausible rate (under 30 m/s).
            var steps: [String: Double] = [:]
            for car in positions {
                guard let s = car.trackDistance, let last = previousDistance[car.id] else { continue }
                steps[car.id] = RaceFormation.wrapped(s - last, length: route.length)
            }
            for (i, a) in positions.enumerated() {
                guard let sa = a.trackDistance else { continue }
                if let stepA = steps[a.id] {
                    let plausible = positions.allSatisfy { b in
                        guard let sb = b.trackDistance, abs(RaceFormation.wrapped(sa - sb, length: route.length)) < 30 else { return true }
                        guard let stepB = steps[b.id] else { return false }
                        return abs(stepA - stepB) < 1
                    }
                    if plausible, let last = previous[a.id], abs(a.lateralOffset - last) > maxJump {
                        maxJump = abs(a.lateralOffset - last); jumpTime = time; jumpID = a.id
                    }
                }
                previous[a.id] = a.lateralOffset
                previousDistance[a.id] = sa
                for b in positions[(i + 1)...] {
                    guard let sb = b.trackDistance else { continue }
                    let gap = abs(RaceFormation.wrapped(sa - sb, length: route.length))
                    let pairID = a.id + b.id
                    if gap < 8 { if closeSince[pairID] == nil { closeSince[pairID] = time } } else { closeSince[pairID] = nil }
                    guard gap < 6 else { continue }
                    let ta = timing.drivers[a.id]!, tb = timing.drivers[b.id]!
                    guard abs(ta.lateral(at: time) - tb.lateral(at: time)) < RaceFormation.sameRoadTolerance else { continue }
                    // Only moving cars: retired cars share a garage.
                    guard ta.distance(at: time + 1) - ta.distance(at: time) > 10 else { continue }
                    overlapping += 1
                    overlapsByWindow[Int(time / 300), default: 0] += 1
                    if abs(a.lateralOffset - b.lateralOffset) >= RaceFormation.laneWidth * 0.75 { separated += 1; continue }
                    failuresByWindow[Int(time / 300), default: 0] += 1
                    if time - (closeSince[pairID] ?? time) > 1.5 {
                        sustained += 1
                    }
                    if abs(a.lateralOffset) < RaceFormation.laneWidth / 8, abs(b.lateralOffset) < RaceFormation.laneWidth / 8 { bothCentered += 1 }
                    else if a.lateralOffset.sign == b.lateralOffset.sign { sameSide += 1 }
                    let neighbors = positions.filter { other in
                        guard let so = other.trackDistance else { return false }
                        return abs(RaceFormation.wrapped(sa - so, length: route.length)) < 14
                    }.count
                    clusterSizes[neighbors, default: 0] += 1
                }
            }
            time += 1.0 / 30
        }
        let placeSeconds = Date().timeIntervalSince(placeStart)
        print("""
        FORMATION timing \(timingSeconds)s formation \(formationSeconds)s \
        placements \(placements) in \(placeSeconds)s (\(placeSeconds / Double(placements) * 1000) ms each) \
        overlapping moving pair-frames \(overlapping) separated \(separated) maxJump \(maxJump) at \(jumpTime) for \(jumpID)
        failures by 5 min window: \(failuresByWindow.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)/\(overlapsByWindow[$0.key] ?? 0)" })
        bothCentered \(bothCentered) sameSide \(sameSide) sustained \(sustained) cars within 14 m of a: \(clusterSizes.sorted { $0.key < $1.key })
        """)
        XCTAssertGreaterThan(overlapping, 0)
        // Brief overlaps remain where a car is lapped at speed, or teleports in the feed;
        // sustained ones (past the lane transition) must be rare.
        XCTAssertGreaterThan(Double(separated) / Double(overlapping), 0.8)
        XCTAssertLessThan(Double(sustained) / Double(overlapping), 0.02)
        // Eased motion bounds the per-frame change: a full-width lane swing plus the overlap ramp
        // closing at 30 m/s. Anything above this is a discontinuity.
        let width = 2 * RaceFormation.maxLane * RaceFormation.laneWidth
        let laneStep = width * 1.5 / RaceFormation.laneTransition / 30
        let weightStep = 1.5 / (RaceFormation.separationDistance - RaceFormation.fullOverlapDistance) * width / 2
        XCTAssertLessThan(maxJump, laneStep + weightStep)
        XCTAssertLessThan(maxJump, 0.5, "Frame-to-frame lateral motion stays under half a meter at 30 fps.")
        XCTAssertLessThan(formationSeconds, 5)
    }
}

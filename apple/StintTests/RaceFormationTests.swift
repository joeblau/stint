import XCTest
import MapKit
@testable import Stint

final class RaceFormationTests: XCTestCase {
    /// A 1 km clockwise square: every corner turns right, so the inside is always the right side.
    private static let circuit = [
        GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0.00225, longitude: 0),
        GeoPoint(latitude: 0.00225, longitude: 0.00225), GeoPoint(latitude: 0, longitude: 0.00225),
        GeoPoint(latitude: 0, longitude: 0),
    ]
    private static let route = CircuitRoute(points: circuit)

    /// Drives along the circuit at `distance(time)` meters, `lateral` meters right of the centerline.
    private func recording(_ id: String, position: Int, duration: Double = 60, lateral: Double = 0,
                           distance: @escaping (Double) -> Double) -> DriverRecording {
        let route = Self.route
        let samples = stride(from: 0.0, through: duration, by: 0.25).map { time -> PositionSample in
            let along = distance(time)
            let heading = route.point(at: along - 1).bearing(to: route.point(at: along + 1))
            let point = route.point(at: along).offset(meters: lateral, bearing: heading + 90)
            return PositionSample(time: time, latitude: point.latitude, longitude: point.longitude,
                                  heading: heading, speedKPH: 180, racePosition: position)
        }
        return DriverRecording(driver: Driver(id: id, name: id, number: position, color: "#FFFFFF"), samples: samples)
    }

    private func build(_ recordings: [DriverRecording]) throws -> (RaceReplay, RaceFormation) {
        let replay = try RaceReplay(version: 1, title: "Formation", circuit: Self.circuit, recordings: recordings).validated()
        return (replay, RaceFormation(replay: replay, timing: RaceTiming(replay: replay)))
    }

    private func offsets(_ replay: RaceReplay, _ formation: RaceFormation, at time: Double) -> [String: Double] {
        let placed = formation.place(replay.recordings.map { $0.position(at: time) }, at: time)
        return Dictionary(uniqueKeysWithValues: placed.map { ($0.id, $0.lateralOffset) })
    }

    func testAttackerTakesTheInsideAndBothCarsReturnToCenterAfterThePass() throws {
        // B closes from 30 m behind at 2 m/s, draws level at 15 s, and is 30 m ahead at 30 s.
        let a = recording("A", position: 1) { 100 + 50 * $0 }
        let b = recording("B", position: 2) { 70 + 52 * $0 }
        let (replay, formation) = try build([a, b])
        XCTAssertEqual(offsets(replay, formation, at: 0)["A"], 0)
        XCTAssertEqual(offsets(replay, formation, at: 0)["B"], 0)
        let alongside = offsets(replay, formation, at: 15)
        XCTAssertEqual(alongside["B"]!, RaceFormation.laneWidth / 2, accuracy: 0.01, "The attacker takes the inside (right) lane.")
        XCTAssertEqual(alongside["A"]!, -RaceFormation.laneWidth / 2, accuracy: 0.01)
        // Sides persist after the pass while the cars still overlap.
        let passed = offsets(replay, formation, at: 19)
        XCTAssertGreaterThan(passed["B"]!, 0.15)
        XCTAssertLessThan(passed["A"]!, -0.15)
        XCTAssertEqual(offsets(replay, formation, at: 30)["A"], 0)
        XCTAssertEqual(offsets(replay, formation, at: 30)["B"], 0)
        // Placement never jumps between display frames.
        var previous = offsets(replay, formation, at: 0)
        for frame in 1...(30 * 60) {
            let current = offsets(replay, formation, at: Double(frame) / 60)
            for id in ["A", "B"] { XCTAssertLessThan(abs(current[id]! - previous[id]!), 0.08, "at frame \(frame)") }
            previous = current
        }
        let placed = formation.place(replay.recordings.map { $0.position(at: 15) }, at: 15)
        XCTAssertEqual(try XCTUnwrap(placed[0].trackDistance), 850, accuracy: 2)
        XCTAssertEqual(placed[0].point, a.position(at: 15).point, "Recorded coordinates are the longitudinal authority.")
    }

    func testThreeAbreastUseThreeLanesAndDifferentRoadsAreNotSeparated() throws {
        let a = recording("A", position: 1) { 100 + 50 * $0 }
        let b = recording("B", position: 2) { 97 + 50 * $0 }
        let c = recording("C", position: 3) { 94 + 50 * $0 }
        let (replay, formation) = try build([a, b, c])
        let lanes = offsets(replay, formation, at: 30).values.sorted()
        XCTAssertEqual(lanes.count, 3)
        XCTAssertEqual(lanes[1] - lanes[0], RaceFormation.laneWidth, accuracy: 0.01)
        XCTAssertEqual(lanes[2] - lanes[1], RaceFormation.laneWidth, accuracy: 0.01)
        XCTAssertEqual(lanes[1], 0, accuracy: 0.01)

        // A car in the pit lane beside the track shares no lane with the car it passes.
        let pit = recording("P", position: 2, lateral: 14) { 100 + 50 * $0 }
        let (pitReplay, pitFormation) = try build([a, pit])
        for time in stride(from: 0.0, through: 60, by: 2) {
            XCTAssertEqual(offsets(pitReplay, pitFormation, at: time)["A"], 0)
            XCTAssertEqual(offsets(pitReplay, pitFormation, at: time)["P"], 0)
        }
    }

    func testRecentPairsKeepTheirSidesWhenTheyMeetAgain() throws {
        // B draws level at 15 s, pulls 25 m clear by 27.5 s, then drops back level by 40 s.
        let gap: (Double) -> Double = { time in
            if time <= 15 { return -30 + 2 * time }
            if time <= 27.5 { return (time - 15) * 2 }
            return max(0, 25 - (time - 27.5) * 2)
        }
        let a = recording("A", position: 1) { 100 + 50 * $0 }
        let b = recording("B", position: 2) { 100 + 50 * $0 + gap($0) }
        let (replay, formation) = try build([a, b])
        let first = offsets(replay, formation, at: 15)
        let separated = offsets(replay, formation, at: 27.5)
        let again = offsets(replay, formation, at: 45)
        XCTAssertEqual(separated["A"], 0)
        XCTAssertEqual(separated["B"], 0)
        XCTAssertEqual(first["A"]!.sign, again["A"]!.sign)
        XCTAssertEqual(first["B"]!.sign, again["B"]!.sign)
        XCTAssertEqual(abs(again["B"]!), RaceFormation.laneWidth / 2, accuracy: 0.01)
    }

    func testProjectionReportsSignedOffsetAcrossTheRoute() {
        let route = Self.route
        // The first side runs north; a point east of it is to the right of travel.
        let east = GeoPoint(latitude: 0.001, longitude: 3 / 111_320)
        let west = GeoPoint(latitude: 0.001, longitude: -3 / 111_320)
        XCTAssertEqual(route.project(east, hint: nil).lateral, 3, accuracy: 0.01)
        XCTAssertEqual(route.project(west, hint: nil).lateral, -3, accuracy: 0.01)
        XCTAssertEqual(route.project(east, hint: nil).distance, 0.001 * 111_320, accuracy: 0.5)
    }

    @MainActor func testSessionPlacesCarsOnceTimingIsReadyAndSeekingIsDeterministic() async throws {
        let a = recording("A", position: 1) { 100 + 50 * $0 }
        let b = recording("B", position: 2) { 97 + 50 * $0 }
        let replay = try RaceReplay(version: 1, title: "Session", circuit: Self.circuit, recordings: [a, b]).validated()
        let session = RaceSession()
        session.install(replay, source: "OPENF1")
        session.isPlaying = false
        session.time = 30
        for _ in 0..<200 where session.formation == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(session.formation)
        let placed = session.positions
        XCTAssertEqual(Set(placed.map(\.lateralOffset)), [RaceFormation.laneWidth / 2, -RaceFormation.laneWidth / 2])
        XCTAssertEqual(placed.map(\.id), session.positions(at: 30).map(\.id))
        session.time = 10
        session.time = 30
        XCTAssertEqual(session.positions.map(\.lateralOffset), placed.map(\.lateralOffset))
        XCTAssertEqual(session.standings.map(\.id), ["A", "B"], "Standings still follow recorded race positions.")

        // The map draws the offset in screen space, scaled with the exaggerated car size.
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        surface.displayFrame(at: 100)
        let first = try XCTUnwrap(surface.projectedPositions["A"])
        let second = try XCTUnwrap(surface.projectedPositions["B"])
        XCTAssertGreaterThan(hypot(first.x - second.x, first.y - second.y), 10)
    }
}

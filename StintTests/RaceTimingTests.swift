import XCTest
@testable import Stint

final class RaceTimingTests: XCTestCase {
    /// A 1 km square circuit whose first point is the start/finish line.
    private static let circuit = [
        GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0.00225, longitude: 0),
        GeoPoint(latitude: 0.00225, longitude: 0.00225), GeoPoint(latitude: 0, longitude: 0.00225),
        GeoPoint(latitude: 0, longitude: 0),
    ]

    /// Drives `laps` laps at a constant lap time, starting `offset` meters before the line.
    private func recording(id: String, lapTime: Double, laps: Double, offset: Double = 30,
                           position: Int? = nil, stints: [TyreStint]? = nil, pitStops: [PitStop]? = nil) -> DriverRecording {
        let route = CircuitRoute(points: Self.circuit)
        let speed = route.length / lapTime
        let samples = stride(from: 0.0, through: lapTime * laps, by: 0.5).map { time -> PositionSample in
            let point = route.point(at: time * speed - offset)
            return PositionSample(time: time, latitude: point.latitude, longitude: point.longitude, heading: 0,
                                  speedKPH: speed * 3.6, racePosition: position)
        }
        return DriverRecording(driver: Driver(id: id, name: id, number: 1, color: "#FFFFFF"), samples: samples,
                               stints: stints, pitStops: pitStops)
    }

    private func replay(_ recordings: [DriverRecording]) throws -> RaceReplay {
        try RaceReplay(version: 1, title: "Timing", circuit: Self.circuit, recordings: recordings).validated()
    }

    func testCountsLapsAndSectorsFromLineCrossings() throws {
        let lapTime = 60.0
        let timing = RaceTiming(replay: try replay([recording(id: "A", lapTime: lapTime, laps: 2.5, position: 1)]))
        let driver = try XCTUnwrap(timing.drivers["A"])
        XCTAssertEqual(driver.laps.count, 2)
        for lap in driver.laps {
            XCTAssertEqual(try XCTUnwrap(lap.time), lapTime, accuracy: 0.6)
            for sector in lap.sectors { XCTAssertEqual(try XCTUnwrap(sector), lapTime / 3, accuracy: 0.6) }
        }
        XCTAssertEqual(driver.lapsCompleted(at: 0), 0)
        XCTAssertEqual(driver.lapsCompleted(at: lapTime + 5), 1)
        XCTAssertEqual(driver.lapsCompleted(at: 2 * lapTime + 5), 2)
    }

    func testGapsIntervalsAndSessionBests() throws {
        // B laps one second slower than A and starts one car length further back.
        let a = recording(id: "A", lapTime: 60, laps: 3, offset: 30, position: 1)
        let b = recording(id: "B", lapTime: 61, laps: 3, offset: 40, position: 2)
        let timing = RaceTiming(replay: try replay([a, b]))
        let order = [a.position(at: 150), b.position(at: 150)]
        let rows = timing.rows(at: 150, order: order)
        XCTAssertEqual(rows["A"]?.gap, .leader)
        guard case .time(let gap)? = rows["B"]?.gap else { return XCTFail("Expected a time gap") }
        // After two laps B is roughly two seconds plus the grid offset behind.
        XCTAssertEqual(gap, 2 + 10 / (1000 / 61), accuracy: 0.8)
        XCTAssertEqual(rows["B"]?.interval, rows["B"]?.gap)
        XCTAssertEqual(rows["A"]?.lastLapHighlight, .sessionBest)
        XCTAssertEqual(rows["A"]?.bestLapHighlight, .sessionBest)
        XCTAssertEqual(rows["B"]?.bestLapHighlight, RaceTiming.Highlight.none)
        XCTAssertEqual(rows["B"]?.lastLapHighlight, RaceTiming.Highlight.personalBest)
        XCTAssertEqual(rows["A"]?.lapsCompleted, 2)
        XCTAssertEqual(rows["A"]?.sectors.map { $0.highlight }, [.sessionBest, .sessionBest, .sessionBest])
    }

    func testValuesNeverComeFromLaterInTheReplay() throws {
        let timing = RaceTiming(replay: try replay([recording(id: "A", lapTime: 60, laps: 3, position: 1)]))
        let car = try XCTUnwrap(timing.drivers["A"])
        let rows = timing.rows(at: 30, order: [CarPosition(driver: Driver(id: "A", name: "A", number: 1, color: "#FFFFFF"),
                                                            point: GeoPoint(latitude: 0, longitude: 0), heading: 0,
                                                            speedKPH: nil, racePosition: 1)])
        XCTAssertNil(rows["A"]?.lastLap)
        XCTAssertNil(rows["A"]?.bestLap)
        XCTAssertEqual(rows["A"]?.sectors[0].time == nil, car.crossings.first { $0.index == 1 }.map { $0.time > 30 } ?? true)
    }

    func testTyresPitStopsAndDiffUseReplayMetadata() throws {
        var recording = recording(id: "A", lapTime: 60, laps: 3, position: 1,
                                  stints: [TyreStint(startLap: 1, compound: "M"), TyreStint(startLap: 3, compound: "H")],
                                  pitStops: [PitStop(lap: 2, entryTime: 100, exitTime: 120, stationary: 2.4)])
        recording.gridPosition = 4
        let timing = RaceTiming(replay: try replay([recording]))
        let position = recording.position(at: 0)
        func rows(_ time: Double) -> RaceTiming.Row? { timing.rows(at: time, order: [position])["A"] }
        XCTAssertEqual(rows(10)?.tyre?.compound, "M")
        XCTAssertEqual(rows(10)?.tyre?.age, 1)
        XCTAssertEqual(rows(70)?.tyre?.age, 2)
        XCTAssertEqual(rows(130)?.tyre?.compound, "H")
        XCTAssertEqual(rows(130)?.tyre?.age, 1)
        XCTAssertEqual(rows(10)?.pit, RaceTiming.Row.PitState.none)
        XCTAssertEqual(rows(110)?.pit, .inLane)
        XCTAssertEqual(rows(130)?.pit, .out)
        XCTAssertEqual(rows(170)?.pit, .stops(count: 1, last: 2.4))
        XCTAssertEqual(rows(10)?.diff, 3)
    }

    func testRejectsInvalidMetadata() throws {
        var bad = recording(id: "A", lapTime: 60, laps: 1, stints: [TyreStint(startLap: 2, compound: "X")])
        XCTAssertThrowsError(try replay([bad]))
        bad = recording(id: "A", lapTime: 60, laps: 1, pitStops: [PitStop(lap: 1, entryTime: 50, exitTime: 40)])
        XCTAssertThrowsError(try replay([bad]))
        bad = recording(id: "A", lapTime: 60, laps: 1)
        bad.gridPosition = 30
        XCTAssertThrowsError(try replay([bad]))
    }

    func testColumnOrderRestoresAndAppendsMissingColumns() {
        let order = StandingsColumn.order(from: "laps,bogus,gap,laps")
        XCTAssertEqual(Array(order.prefix(2)), [.laps, .gap])
        XCTAssertEqual(Set(order), Set(StandingsColumn.allCases))
        XCTAssertEqual(order.count, StandingsColumn.allCases.count)
        XCTAssertEqual(StandingsColumn.order(from: StandingsColumn.stored(order)), order)
    }

    func testLapStringFormatting() {
        XCTAssertEqual(RaceTiming.lapString(83.456), "1:23.456")
        XCTAssertEqual(RaceTiming.lapString(59.9), "59.900")
    }
}

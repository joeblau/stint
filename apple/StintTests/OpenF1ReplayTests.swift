import XCTest
import simd
@testable import Stint

final class OpenF1ReplayTests: XCTestCase {
    private func race(_ id: String = "monaco") throws -> SeasonRace {
        try XCTUnwrap(Season2026.races.first { $0.circuitID == id })
    }

    func testSessionMatchingRejectsWrongYearWeekendVenueAndCancelledRaces() throws {
        let race = try race()
        func session(year: Int = 2026, name: String = "Race", circuit: String = "Monte Carlo", date: Date? = nil, cancelled: Bool = false) -> OpenF1.Session {
            OpenF1.Session(sessionKey: 11299, sessionName: name, dateStart: date ?? race.lightingStartDate,
                           dateEnd: race.lightingStartDate.addingTimeInterval(7200), circuitShortName: circuit, year: year, isCancelled: cancelled)
        }
        XCTAssertTrue(session().matches(race))
        XCTAssertFalse(session(year: 2025).matches(race))
        XCTAssertFalse(session(name: "Sprint").matches(race))
        XCTAssertFalse(session(circuit: "Monza").matches(race))
        XCTAssertFalse(session(date: race.startDate.addingTimeInterval(-1)).matches(race))
        XCTAssertFalse(session(cancelled: true).matches(race))
    }

    func testDecoderHandlesFractionalDatesAndLappedGaps() throws {
        let data = Data("""
        [{"date":"2026-06-07T13:04:37.999000+00:00","driver_number":16,"gap_to_leader":"+1 LAP"},
         {"date":"2026-06-07T13:04:38+00:00","driver_number":1,"gap_to_leader":2.5},
         {"date":"2026-06-07T13:04:38Z","driver_number":4,"gap_to_leader":null}]
        """.utf8)
        let intervals = try OpenF1Client.decoder().decode([OpenF1.Interval].self, from: data)
        XCTAssertNil(intervals[0].gapToLeader?.seconds)
        XCTAssertEqual(intervals[1].gapToLeader?.seconds, 2.5)
        XCTAssertNil(intervals[2].gapToLeader)
        XCTAssertEqual(intervals[1].date.timeIntervalSince(intervals[0].date), 0.001, accuracy: 0.00001)
    }

    func testRealOpenF1LapAlignsToMonacoMap() throws {
        // OpenF1 session 11299, driver 16, lap 2. https://openf1.org/docs/#location
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "openf1-monaco-lap", withExtension: "json"))
        let locations = try OpenF1Client.decoder().decode([OpenF1.Location].self, from: Data(contentsOf: url))
        let circuit = try DemoCircuit.monaco.loadCircuit()
        let transform = try OpenF1MapTransform.fit(lap: locations.map(\.vector), circuit: circuit)
        XCTAssertLessThan(transform.errorMeters, 50)
        let route = CircuitRoute(points: circuit)
        for location in locations {
            let point = transform.point(location.vector)
            XCTAssertTrue(point.isValid)
            let nearest = stride(from: 0.0, to: route.length, by: 10).map { distance -> Double in
                let p = route.point(at: distance)
                return hypot((p.latitude - point.latitude) * 111_320,
                             (p.longitude - point.longitude) * 111_320 * cos(point.latitude * .pi / 180))
            }.min()!
            XCTAssertLessThan(nearest, 90)
        }
    }

    func testIncompleteAndInterruptedLocationCoverageIsRejected() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let laps = [OpenF1.Lap(driverNumber: 16, lapNumber: 1, dateStart: start, lapDuration: 180, isPitOutLap: false)]
        func location(_ time: Double) -> OpenF1.Location { .init(date: start.addingTimeInterval(time), x: 10, y: 20) }
        XCTAssertThrowsError(try OpenF1ReplayBuilder.validateCoverage(locations: [location(0), location(10)], laps: laps, driver: "LEC"))
        XCTAssertThrowsError(try OpenF1ReplayBuilder.validateCoverage(locations: [location(0), location(180)], laps: laps, driver: "LEC"))
        XCTAssertNoThrow(try OpenF1ReplayBuilder.validateCoverage(locations: stride(from: 0.0, through: 180, by: 10).map(location), laps: laps, driver: "LEC"))
    }

    func testDegenerateLocationTraceIsRejected() throws {
        XCTAssertThrowsError(try OpenF1MapTransform.fit(lap: Array(repeating: SIMD2(2.0, 3.0), count: 50), circuit: try DemoCircuit.monaco.loadCircuit()))
    }

    func testConversionSortsDeduplicatesAndDoesNotUseFutureTelemetry() throws {
        let start = Date(timeIntervalSince1970: 1000)
        let transform = OpenF1MapTransform(origin: GeoPoint(latitude: 43.73, longitude: 7.42),
            sourceCenter: .zero, targetCenter: .zero, rotation: SIMD2(1, 0), errorMeters: 0)
        let driver = Driver(id: "LEC", name: "Charles Leclerc", number: 16, color: "#FF0000")
        let locations = [2.0, 1.0, 1.0, 4.0].map { OpenF1.Location(date: start.addingTimeInterval($0), x: $0 * 10, y: 1) }
        let car = OpenF1.CarData(date: start.addingTimeInterval(1.5), speed: 200, throttle: 50, brake: 100, drs: 12, nGear: 5, rpm: 11000)
        let recording = try OpenF1ReplayBuilder.recording(driver: driver, locations: locations, telemetry: [car],
            positions: [], intervals: [], stints: [], transform: transform, start: start, end: start.addingTimeInterval(10))
        XCTAssertEqual(recording.samples.map(\.time), [0, 1, 2, 4])
        XCTAssertNil(recording.samples[1].speedKPH)
        XCTAssertEqual(recording.samples[2].throttle, 0.5)
        XCTAssertEqual(recording.samples[2].brake, 1)
        XCTAssertEqual(recording.samples[2].drs, true)
        XCTAssertNil(recording.samples[3].speedKPH, "Stale telemetry must not be held indefinitely")
        let readout = TelemetryEstimator.estimate(recording: recording, at: 2)
        XCTAssertEqual(readout.gear, 5)
        XCTAssertEqual(readout.rpm, 11000)
        _ = try RaceReplay(version: 1, title: "Test", circuit: try DemoCircuit.monaco.loadCircuit(), recordings: [recording]).validated()
    }

    func testStorageSurvivesNewInstanceAndRejectsWrongRace() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReplayStorage(directory: directory)
        let race = try race()
        var replay = try race.circuit.load()
        replay.startDate = race.lightingStartDate
        let saved = SavedRaceReplay(version: 1, circuitID: race.circuitID, year: 2026, sessionKey: 11299, downloadedAt: Date(), replay: replay)
        try storage.save(saved)
        let reopened = ReplayStorage(directory: directory)
        XCTAssertTrue(reopened.savedCircuitIDs().contains("monaco"))
        let loaded = try reopened.load(race)
        XCTAssertEqual(loaded.replay.startDate, replay.startDate)
        XCTAssertEqual(loaded.replay.duration, replay.duration)
        try FileManager.default.copyItem(at: storage.url(for: "monaco"), to: storage.url(for: "monza"))
        XCTAssertThrowsError(try reopened.load(self.race("monza")))
    }

    @MainActor func testDownloadedStartTimeDrivesRaceLighting() throws {
        let session = RaceSession()
        var replay = try DemoCircuit.monaco.load()
        replay.startDate = try race().calendar.date(bySettingHour: 23, minute: 0, second: 0, of: race().endDate)
        session.install(replay, source: "OPENF1")
        session.demoCircuit = .monaco
        XCTAssertFalse(session.lightingIsDay)
        XCTAssertEqual(session.lightingTimeLabel, "Race time · 23:00 local")
    }
}

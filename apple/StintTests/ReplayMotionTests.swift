import XCTest
@testable import Stint

final class ReplayMotionTests: XCTestCase {
    private let driver = Driver(id: "TST", name: "Test", number: 1, color: "#FFFFFF")

    private func sample(_ time: Double, x: Double, y: Double = 0, speed: Double? = 180) -> PositionSample {
        PositionSample(time: time, latitude: y / 111_320, longitude: x / 111_320,
                       heading: 90, speedKPH: speed, racePosition: 2, gapToLeader: time,
                       throttle: min(1, time / 10), brake: 0, drs: time > 1, gear: 5, rpm: 11_000)
    }

    private func x(_ position: CarPosition) -> Double { position.point.longitude * 111_320 }

    func testConstantSpeedStaysLinearThroughSampleBoundariesAndEndpoints() {
        let samples = [0.0, 0.1, 0.35, 0.6, 1.0, 1.2, 1.7, 2.0].map { sample($0, x: $0 * 50) }
        let recording = DriverRecording(driver: driver, samples: samples).preparingMotion()
        for frame in 0...120 {
            let time = Double(frame) / 60
            XCTAssertEqual(x(recording.position(at: time)), time * 50, accuracy: 0.0001)
        }
        XCTAssertEqual(x(recording.position(at: -1)), 0, accuracy: 0.0001)
        XCTAssertEqual(x(recording.position(at: 3)), 100, accuracy: 0.0001)
    }

    func testUnevenLocationTimestampsDoNotCauseRepeatedSurges() {
        let samples = (0...40).map { index in
            sample(Double(index) * 0.25 + (index.isMultiple(of: 2) ? 0 : 0.08), x: Double(index) * 12.5)
        }
        let raw = DriverRecording(driver: driver, samples: samples)
        let smooth = raw.preparingMotion()
        func velocities(_ recording: DriverRecording) -> [Double] {
            (60..<540).map { frame in
                let time = Double(frame) / 60
                return (x(recording.position(at: time + 1 / 60.0)) - x(recording.position(at: time))) * 60
            }
        }
        func jitter(_ values: [Double]) -> Double {
            zip(values, values.dropFirst()).reduce(0) { $0 + abs($1.1 - $1.0) }
        }
        let filtered = velocities(smooth)
        XCTAssertLessThan(jitter(filtered), jitter(velocities(raw)) * 0.15)
        XCTAssertGreaterThan(filtered.min()!, 40)
        XCTAssertLessThan(filtered.max()!, 60)
        for time in stride(from: 0.0, through: 10, by: 0.05) {
            let a = raw.position(at: time), b = smooth.position(at: time)
            XCTAssertEqual(a.speedKPH, b.speedKPH)
            XCTAssertEqual(a.throttle, b.throttle)
            XCTAssertEqual(a.drs, b.drs)
            XCTAssertEqual(a.gear, b.gear)
            XCTAssertEqual(a.rpm, b.rpm)
            XCTAssertEqual(a.racePosition, b.racePosition)
            XCTAssertEqual(a.gapToLeader, b.gapToLeader)
        }
    }

    func testSmoothingFollowsRecordedCornersWithoutCuttingAcrossThem() {
        let recording = DriverRecording(driver: driver, samples: [
            sample(0, x: 0), sample(0.2, x: 10), sample(0.55, x: 20),
            sample(0.7, x: 20, y: 10), sample(1, x: 20, y: 20)
        ]).preparingMotion()
        for time in stride(from: 0.0, through: 1, by: 0.01) {
            let point = recording.position(at: time).point
            let x = point.longitude * 111_320, y = point.latitude * 111_320
            XCTAssertTrue(abs(y) < 0.0001 || abs(x - 20) < 0.0001)
            XCTAssertTrue((-0.0001...20.0001).contains(x))
            XCTAssertTrue((-0.0001...20.0001).contains(y))
        }
    }

    func testStopsAndFeedGapsRemainBoundaries() {
        let raw = DriverRecording(driver: driver, samples: [
            sample(0, x: 0), sample(0.2, x: 10), sample(0.5, x: 20),
            sample(0.8, x: 20), sample(1, x: 20),
            sample(1.2, x: 30), sample(1.5, x: 40),
            sample(5, x: 100), sample(5.2, x: 110), sample(5.5, x: 120)
        ])
        let smooth = raw.preparingMotion()
        for time in stride(from: 0.5, through: 1, by: 0.01) {
            XCTAssertEqual(x(smooth.position(at: time)), 20, accuracy: 0.0001)
        }
        for time in [0.0, 0.5, 1, 1.5, 2, 3, 4, 5, 5.5] {
            XCTAssertEqual(x(smooth.position(at: time)), x(raw.position(at: time)), accuracy: 0.0001)
        }
        // Approaching either side of a stop must not cause a position jump.
        XCTAssertEqual(x(smooth.position(at: 0.5 - 0.000001)), 20, accuracy: 0.001)
        XCTAssertEqual(x(smooth.position(at: 1 + 0.000001)), 20, accuracy: 0.001)
    }

    func testPlaybackIndexDoesNotChangeSavedData() throws {
        let raw = DriverRecording(driver: driver, samples: [sample(0, x: 0), sample(0.2, x: 10), sample(0.5, x: 20)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(try encoder.encode(raw), try encoder.encode(raw.preparingMotion()))
    }

    @MainActor func testOpeningExistingDownloadPreparesMotionAndSeekingIsDeterministic() throws {
        let recording = DriverRecording(driver: driver, samples: (0...12).map { index in
            sample(Double(index) * 0.25 + (index.isMultiple(of: 2) ? 0 : 0.08), x: Double(index) * 12.5)
        })
        let replay = RaceReplay(version: 1, title: "Downloaded", circuit: [
            GeoPoint(latitude: 0, longitude: 0), GeoPoint(latitude: 0, longitude: 0.01),
            GeoPoint(latitude: 0.01, longitude: 0)
        ], recordings: [recording])
        let reopened = try JSONDecoder().decode(RaceReplay.self, from: JSONEncoder().encode(replay))
        let session = RaceSession()
        session.install(reopened, source: "OPENF1")
        session.time = 1.25
        let displayed = try XCTUnwrap(session.selectedPosition)
        XCTAssertGreaterThan(abs(x(displayed) - x(recording.position(at: 1.25))), 1)
        session.time = 0.5
        session.time = 1.25
        XCTAssertEqual(session.selectedPosition?.point, displayed.point)
        XCTAssertEqual(session.selectedPosition?.gapToLeader, recording.position(at: 1.25).gapToLeader)
        session.install(reopened, source: "SIMULATED")
        session.time = 1.25
        XCTAssertEqual(session.selectedPosition?.point, recording.position(at: 1.25).point)
    }
}

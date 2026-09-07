import XCTest
@testable import Stint

final class RaceDataTests: XCTestCase {
    private let driver = Driver(id: "TST", name: "Test Driver", number: 7, color: "#FF8700")
    private let circuit = [GeoPoint(latitude: 43.73, longitude: 7.42),
                           GeoPoint(latitude: 43.74, longitude: 7.43),
                           GeoPoint(latitude: 43.73, longitude: 7.44)]

    private func sample(_ time: Double, heading: Double = 0, longitude: Double = 7.42) -> PositionSample {
        PositionSample(time: time, latitude: 43.73, longitude: longitude, heading: heading, speedKPH: 200)
    }

    private func replay(_ samples: [PositionSample]) -> RaceReplay {
        RaceReplay(version: 1, title: "Test", circuit: circuit,
                   recordings: [DriverRecording(driver: driver, samples: samples)])
    }

    func testHeadingInterpolatesAcrossNorthWithoutSpinning() throws {
        let data = try replay([sample(0, heading: 350), sample(10, heading: 10)]).validated()
        XCTAssertEqual(data.recordings[0].position(at: 5).heading, 0, accuracy: 0.001)
        XCTAssertEqual(data.recordings[0].position(at: 2.5).heading, 355, accuracy: 0.001)
    }

    func testInterpolationAndClamping() throws {
        let data = try replay([sample(0, longitude: 7), sample(10, longitude: 8), sample(20, longitude: 10)]).validated()
        let recording = data.recordings[0]
        XCTAssertEqual(recording.position(at: 5).point.longitude, 7.5, accuracy: 0.00001)
        XCTAssertEqual(recording.position(at: 15).point.longitude, 9, accuracy: 0.00001)
        XCTAssertEqual(recording.position(at: -1).point.longitude, 7, accuracy: 0.00001)
        XCTAssertEqual(recording.position(at: 100).point.longitude, 10, accuracy: 0.00001)
    }

    func testRejectsDuplicateOrUnorderedTimes() {
        XCTAssertThrowsError(try replay([sample(0), sample(0)]).validated())
        XCTAssertThrowsError(try replay([sample(0), sample(10), sample(5)]).validated())
        XCTAssertThrowsError(try replay([sample(2), sample(10)]).validated())
    }

    func testRejectsInvalidCoordinatesAndHeading() {
        XCTAssertThrowsError(try replay([sample(0), sample(1, longitude: 181)]).validated())
        XCTAssertThrowsError(try replay([sample(0), sample(1, heading: .nan)]).validated())
        XCTAssertThrowsError(try replay([sample(0), sample(1, heading: 360)]).validated())
    }

    func testRejectsDuplicateDriverIDs() {
        let recording = DriverRecording(driver: driver, samples: [sample(0), sample(10)])
        XCTAssertThrowsError(try RaceReplay(version: 1, title: "Test", circuit: circuit,
                                           recordings: [recording, recording]).validated())
    }

    func testLongitudeInterpolationUsesShortPathAcrossDateLine() {
        let point = GeoPoint(latitude: 0, longitude: 179).interpolated(to: GeoPoint(latitude: 0, longitude: -179), fraction: 0.5)
        XCTAssertEqual(abs(point.longitude), 180, accuracy: 0.00001)
    }

    func testRouteWrapsAtStartFinish() {
        let route = CircuitRoute(points: circuit + [circuit[0]])
        XCTAssertEqual(route.point(at: 0).latitude, route.point(at: route.length).latitude, accuracy: 0.00001)
        XCTAssertEqual(route.point(at: -10).longitude, route.point(at: route.length - 10).longitude, accuracy: 0.00001)
    }

    @MainActor func testBundledCircuitsLoadAndPlaybackStopsAtEnd() async throws {
        for circuit in DemoCircuit.allCases {
            let replay = try await Task.detached { try circuit.load() }.value
            XCTAssertEqual(replay.recordings.count, 22)
            XCTAssertGreaterThan(replay.duration, 200)
            XCTAssertGreaterThan(replay.circuit.count, 1_000)
            XCTAssertEqual(replay.recordings[0].samples[1].time, 1.0 / 30, accuracy: 0.000001)
        }
        let session = RaceSession()
        session.time = session.duration - 0.01
        session.advance(by: 0.1)
        XCTAssertEqual(session.time, session.duration)
        XCTAssertFalse(session.isPlaying)
        session.togglePlayback()
        XCTAssertEqual(session.time, 0)
        XCTAssertTrue(session.isPlaying)
    }

    @MainActor func testPausedPlaybackAndBackgroundGap() {
        let session = RaceSession()
        session.isPlaying = false
        session.advance(by: 10)
        XCTAssertEqual(session.time, 0)
        session.isPlaying = true
        session.advance(by: 100)
        XCTAssertEqual(session.time, 0.25)
    }

    @MainActor func testImportReplacesSessionAndInvalidFilePreservesIt() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try JSONEncoder().encode(replay([sample(0), sample(30)])).write(to: url)
        let session = RaceSession()
        await session.importReplay(from: url)
        XCTAssertEqual(session.sourceName, "IMPORTED REPLAY")
        XCTAssertEqual(session.replay?.title, "Test")
        XCTAssertEqual(session.duration, 30)
        XCTAssertNil(session.error)
        let revision = session.revision
        try Data("{invalid json}".utf8).write(to: url)
        await session.importReplay(from: url)
        XCTAssertNotNil(session.error)
        XCTAssertEqual(session.revision, revision)
        XCTAssertEqual(session.replay?.title, "Test")
        XCTAssertFalse(session.importing)
    }
}

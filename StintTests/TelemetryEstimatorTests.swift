import XCTest
@testable import Stint

final class TelemetryEstimatorTests: XCTestCase {
    func testRecordedDRSOverridesEstimateAtSampleBoundary() {
        let samples = [
            PositionSample(time: 0, latitude: 43.73, longitude: 7.42, heading: 90, speedKPH: 150, drs: true),
            PositionSample(time: 1, latitude: 43.73, longitude: 7.42, heading: 90, speedKPH: 320, throttle: 1, drs: false)
        ]
        let recording = DriverRecording(driver: driver, samples: samples)
        XCTAssertTrue(TelemetryEstimator.estimate(recording: recording, at: 0.5).drs)
        XCTAssertFalse(TelemetryEstimator.estimate(recording: recording, at: 1).drs)
    }

    func testRecordedPedalsInterpolateAtConstantSpeed() {
        let samples = [
            PositionSample(time: 0, latitude: 43.73, longitude: 7.42, heading: 90, speedKPH: 150, throttle: 0.2, brake: 0),
            PositionSample(time: 1, latitude: 43.73, longitude: 7.42, heading: 90, speedKPH: 150, throttle: 0.8, brake: 0.4)
        ]
        let telemetry = TelemetryEstimator.estimate(recording: DriverRecording(driver: driver, samples: samples), at: 0.5)
        XCTAssertEqual(telemetry.throttle, 0.5, accuracy: 0.0001)
        XCTAssertEqual(telemetry.brake, 0.2, accuracy: 0.0001)
    }

    func testSpeedUnitConversion() {
        XCTAssertEqual(GaugeSpeedUnit.mph.value(fromKPH: 150), 93.2057, accuracy: 0.001)
        XCTAssertEqual(GaugeSpeedUnit.kph.value(fromKPH: 150), 150)
    }

    private let driver = Driver(id: "TST", name: "Test Driver", number: 7, color: "#FF8700")

    private func recording(speeds: [Double]) -> DriverRecording {
        DriverRecording(driver: driver, samples: speeds.enumerated().map {
            PositionSample(time: Double($0.offset), latitude: 43.73, longitude: 7.42,
                           heading: 90, speedKPH: $0.element)
        })
    }

    private func recordingNoSpeed() -> DriverRecording {
        // 0.001° longitude per second at latitude 43.73 ≈ 80.4 m/s ≈ 289.5 km/h.
        DriverRecording(driver: driver, samples: (0...20).map {
            PositionSample(time: Double($0), latitude: 43.73, longitude: 7.42 + 0.001 * Double($0),
                           heading: 90, speedKPH: nil)
        })
    }

    func testConstantSpeedCruising() {
        let telemetry = TelemetryEstimator.estimate(recording: recording(speeds: Array(repeating: 200, count: 21)), at: 10)
        XCTAssertEqual(telemetry.speedKPH ?? 0, 200, accuracy: 0.001)
        XCTAssertEqual(telemetry.gear, 5)
        XCTAssertEqual(telemetry.rpm ?? 0, 11375, accuracy: 1)
        XCTAssertEqual(telemetry.throttle, 0, accuracy: 0.001)
        XCTAssertEqual(telemetry.brake, 0, accuracy: 0.001)
        XCTAssertFalse(telemetry.drs)
    }

    func testHardAccelerationOpensThrottleAndDRS() {
        // 6 m/s² from 100 km/h: v(t) = 100 + 21.6t.
        let telemetry = TelemetryEstimator.estimate(recording: recording(speeds: (0...20).map { 100 + 21.6 * Double($0) }), at: 10)
        XCTAssertEqual(telemetry.speedKPH ?? 0, 316, accuracy: 0.001)
        XCTAssertEqual(telemetry.throttle, 1, accuracy: 0.001)
        XCTAssertEqual(telemetry.brake, 0, accuracy: 0.001)
        XCTAssertEqual(telemetry.gear, 8)
        XCTAssertTrue(telemetry.drs)
    }

    func testHardBraking() {
        // -8 m/s² from 320 km/h: v(t) = 320 - 28.8t.
        let telemetry = TelemetryEstimator.estimate(recording: recording(speeds: (0...10).map { 320 - 28.8 * Double($0) }), at: 5)
        XCTAssertEqual(telemetry.speedKPH ?? 0, 176, accuracy: 0.001)
        XCTAssertEqual(telemetry.brake, 1, accuracy: 0.001)
        XCTAssertEqual(telemetry.throttle, 0, accuracy: 0.001)
        XCTAssertFalse(telemetry.drs)
    }

    func testSpeedDerivedFromGeometryWhenSamplesOmitIt() {
        let telemetry = TelemetryEstimator.estimate(recording: recordingNoSpeed(), at: 10)
        XCTAssertEqual(telemetry.speedKPH ?? 0, 289.5, accuracy: 3)
        XCTAssertNotNil(telemetry.gear)
    }

    func testGearBandsAndIdleRPM() {
        XCTAssertEqual(TelemetryEstimator.gear(for: 0), 1)
        XCTAssertEqual(TelemetryEstimator.gear(for: 69), 1)
        XCTAssertEqual(TelemetryEstimator.gear(for: 70), 2)
        XCTAssertEqual(TelemetryEstimator.gear(for: 299), 7)
        XCTAssertEqual(TelemetryEstimator.gear(for: 300), 8)
        XCTAssertEqual(TelemetryEstimator.gear(for: 400), 8)
        XCTAssertEqual(TelemetryEstimator.rpm(for: 0, gear: 1), 4000)
        XCTAssertEqual(TelemetryEstimator.rpm(for: 360, gear: 8), 12500, accuracy: 1)
    }
}

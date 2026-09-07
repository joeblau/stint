import XCTest
import SceneKit
@testable import Stint

final class CarArticulationTests: XCTestCase {
    private let driver = Driver(id: "TST", name: "Test", number: 1, color: "#E10600")

    private func recording(headings: [Double], distance: Double = 10, drs: [Bool?] = [nil, nil]) -> DriverRecording {
        let origin = GeoPoint(latitude: 43, longitude: 7)
        return DriverRecording(driver: driver, samples: headings.enumerated().map { index, heading in
            let point = origin.offset(meters: Double(index) * distance, bearing: 0)
            return PositionSample(time: Double(index), latitude: point.latitude, longitude: point.longitude,
                                  heading: heading, speedKPH: 150, drs: drs[index])
        })
    }

    func testHeadingWrapAndInsideWheelSteering() {
        let right = CarArticulation.estimate(recording: recording(headings: [359, 1]), at: 0.5)
        XCTAssertLessThan(right.frontLeft, 0)
        XCTAssertLessThan(right.frontRight, right.frontLeft)
        XCTAssertLessThan(abs(right.frontRight), 0.1, "Crossing north must not produce a full turn.")
        let left = CarArticulation.estimate(recording: recording(headings: [1, 359]), at: 0.5)
        XCTAssertGreaterThan(left.frontRight, 0)
        XCTAssertGreaterThan(left.frontLeft, left.frontRight)
        XCTAssertEqual(left.frontLeft, -right.frontRight, accuracy: 0.00001)
    }

    func testSteeringMatchesPathRadius() {
        let angle = 10.0 / 20 * 180 / Double.pi
        let pose = CarArticulation.estimate(recording: recording(headings: [0, angle]), at: 0.5)
        XCTAssertEqual(pose.frontLeft, -atan(2.85 / (20 + 0.93)), accuracy: 0.002)
        XCTAssertEqual(pose.frontRight, -atan(2.85 / (20 - 0.93)), accuracy: 0.002)
    }

    func testStraightStationaryAndExtremeTurnsStayStable() {
        for source in [recording(headings: [90, 90]), recording(headings: [0, 90], distance: 0)] {
            let pose = CarArticulation.estimate(recording: source, at: 0.5)
            XCTAssertEqual(pose.frontLeft, 0)
            XCTAssertEqual(pose.frontRight, 0)
        }
        let source = recording(headings: [0, 170], distance: 0.2)
        for time in [-1.0, 0, 0.5, 1, 2] {
            let pose = CarArticulation.estimate(recording: source, at: time)
            XCTAssertTrue(pose.frontLeft.isFinite && pose.frontRight.isFinite)
            XCTAssertLessThanOrEqual(abs(pose.frontLeft), CarArticulation.maximumSteering)
            XCTAssertLessThanOrEqual(abs(pose.frontRight), CarArticulation.maximumSteering)
        }
    }

    func testRecordedDRSAndSeekingMatchGauge() {
        let source = recording(headings: [0, 0], drs: [true, false])
        for time in [0.0, 0.99, 1, 0.5] {
            let pose = CarArticulation.estimate(recording: source, at: time)
            XCTAssertEqual(pose.drsOpen, TelemetryEstimator.estimate(recording: source, at: time).drs)
            XCTAssertEqual(pose.drsOpen, time < 1)
        }
    }

    func testEstimatedDRSMatchesGaugeWhenRecordingOmitsIt() {
        let source = DriverRecording(driver: driver, samples: (0...20).map {
            PositionSample(time: Double($0), latitude: 43 + Double($0) * 0.001, longitude: 7,
                           heading: 0, speedKPH: 100 + Double($0) * 21.6)
        })
        let pose = CarArticulation.estimate(recording: source, at: 10)
        XCTAssertTrue(pose.drsOpen)
        XCTAssertEqual(pose.drsOpen, TelemetryEstimator.estimate(recording: source, at: 10).drs)
    }

    func testOnlyFrontWheelsAndWingFlapArticulate() throws {
        let rig = CarGeometry.make(color: "#E10600")
        let leftPosition = rig.frontLeft.position
        let hingePosition = rig.rearFlap.position
        rig.apply(.init(frontLeft: -0.2, frontRight: -0.24, drsOpen: true), animated: false)
        XCTAssertEqual(rig.frontLeft.simdEulerAngles.y, -0.2, accuracy: 0.0001)
        XCTAssertEqual(rig.frontRight.simdEulerAngles.y, -0.24, accuracy: 0.0001)
        XCTAssertEqual(rig.rearFlap.simdEulerAngles.x, 0, accuracy: 0.0001)
        XCTAssertEqual(rig.frontLeft.position.x, leftPosition.x)
        XCTAssertEqual(rig.frontLeft.position.z, leftPosition.z)
        XCTAssertEqual(rig.rearFlap.position.y, hingePosition.y)
        XCTAssertEqual(rig.rearFlap.position.z, hingePosition.z)
        XCTAssertEqual(rig.root.eulerAngles.y, 0)
        for side in ["left", "right"] {
            let rear = try XCTUnwrap(rig.root.childNode(withName: "rear-\(side)-wheel", recursively: false))
            XCTAssertEqual(rear.eulerAngles.y, 0)
        }
        rig.apply(.init(frontLeft: 0, frontRight: 0, drsOpen: false), animated: false)
        XCTAssertEqual(rig.frontLeft.simdEulerAngles.y, 0, accuracy: 0.0001)
        XCTAssertEqual(rig.rearFlap.simdEulerAngles.x, CarGeometry.Rig.closedFlapAngle, accuracy: 0.0001)
    }
}

import XCTest
import MapKit
import SceneKit
@testable import Stint

final class RenderingPerformanceTests: XCTestCase {
    @MainActor func testDisplayClockKeepsFullPrecisionWithTenHUDUpdatesPerSecond() {
        let session = RaceSession()
        var publications = 0
        var last = session.time
        for _ in 0..<60 {
            session.advanceFrame(by: 1.0 / 60)
            if session.time != last { publications += 1; last = session.time }
        }
        XCTAssertEqual(session.renderTime, 1, accuracy: 0.000001)
        XCTAssertTrue((9...10).contains(publications))
        XCTAssertLessThanOrEqual(session.renderTime - session.time, 0.1)
        session.togglePlayback()
        XCTAssertEqual(session.time, session.renderTime, "Pause publishes the exact displayed frame.")
        let paused = session.renderTime
        session.advanceFrame(by: 1)
        XCTAssertEqual(session.renderTime, paused)
        session.time = 80
        XCTAssertEqual(session.renderTime, 80, "Seeking must bypass HUD throttling.")
        session.togglePlayback()
        session.playbackRate = 4
        session.advanceFrame(by: 1.0 / 60)
        XCTAssertEqual(session.renderTime, 80 + 4.0 / 60, accuracy: 0.000001)
    }

    @MainActor func testMapCallbacksCoalesceAndPausedSceneDoesNoRepeatedProjection() {
        let session = RaceSession()
        session.isPlaying = false
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        surface.displayFrame(at: 100)
        let initial = surface.projectionPassCount
        for _ in 0..<20 { surface.mapViewDidChangeVisibleRegion(surface.map) }
        XCTAssertEqual(surface.projectionPassCount, initial)
        surface.displayFrame(at: 101)
        XCTAssertEqual(surface.projectionPassCount, initial + 1)
        for frame in 1...60 { surface.displayFrame(at: 101 + Double(frame) / 60) }
        XCTAssertEqual(surface.projectionPassCount, initial + 1)
        surface.setActive(false)
        session.isPlaying = true
        surface.displayFrame(at: 200)
        XCTAssertEqual(session.renderTime, 0)
    }

    @MainActor func testPausedCarsFollowNativeMapMovementBeforeNextPlaybackTick() async throws {
        let session = RaceSession()
        session.isPlaying = false
        let surface = RaceMapSurface(session: session)
        surface.frame = CGRect(x: 0, y: 0, width: 1280, height: 820)
        surface.layout()
        surface.displayFrame(at: 100)
        let car = try XCTUnwrap(session.selectedPosition)
        for heading in [30.0, 130, 270] {
            let camera = surface.map.camera.copy() as! MKMapCamera
            camera.heading = heading
            camera.pitch = 60
            surface.map.setCamera(camera, animated: false)
            for _ in 0..<10 { surface.mapViewDidChangeVisibleRegion(surface.map) }
            let before = surface.projectionPassCount
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            XCTAssertGreaterThan(surface.projectionPassCount, before)
            let projected = try XCTUnwrap(surface.projectedPositions[car.id])
            let native = surface.map.convert(car.point.coordinate, toPointTo: surface.map)
            XCTAssertEqual(projected.x, native.x, accuracy: 0.5)
            XCTAssertEqual(projected.y, native.y, accuracy: 0.5)
            XCTAssertEqual(session.renderTime, 0, "Map movement must not advance paused replay data.")
        }
        surface.setActive(false)
    }

    @MainActor func testHUDCachesInvalidateOnSeekAndReplayReplacement() throws {
        let session = RaceSession()
        let start = try XCTUnwrap(session.selectedPosition)
        session.time = 30
        XCTAssertNotEqual(session.selectedPosition?.point, start.point)
        session.time = 0
        XCTAssertEqual(session.selectedPosition?.point, start.point)
        session.loadDemo(.silverstone)
        XCTAssertNotEqual(session.selectedPosition?.point, start.point)
        XCTAssertEqual(session.standings.count, 22)
    }

    @MainActor func testTimingPreparationPublishesOnlyTheCurrentReplay() async throws {
        let session = RaceSession()
        session.loadDemo(.silverstone)
        let revision = session.revision
        // A circuit switch must return before the expensive timing index is built.
        XCTAssertNil(session.timing)
        for _ in 0..<200 {
            if session.timing != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(session.revision, revision)
        let timing = try XCTUnwrap(session.timing)
        XCTAssertTrue((5_800...6_000).contains(timing.length), "The completed index must be Silverstone, not the superseded Monaco replay.")
        XCTAssertEqual(session.timingRows.count, 22)
    }

    func testChassisIsBatchedAndLabelsAreSingleQuads() {
        let rig = CarGeometry.make(color: "#E10600")
        XCTAssertNotNil(rig.root.childNode(withName: "chassis", recursively: false)?.geometry)
        XCTAssertLessThan(rig.root.childNodes.count, 10)
        XCTAssertTrue(rig.frontLeft.parent === rig.root)
        XCTAssertTrue(rig.rearFlap.parent === rig.root)
        let label = CarGeometry.label(Driver(id: "NOR", name: "Lando Norris", number: 4, color: "#FF8800"))
        XCTAssertTrue(label.geometry is SCNPlane)
        XCTAssertEqual(label.childNodes.count, 0)
    }
}

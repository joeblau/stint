import XCTest
import SceneKit
@testable import Stint

final class CarSceneRendererTests: XCTestCase {
    func testNewestFrameWinsAndHiddenCarsDoNotRetainStaleVisibility() {
        let consumer = CarSceneRenderer()
        let renderer = SCNRenderer(device: nil, options: nil)
        let camera = SCNNode()
        camera.camera = SCNCamera()
        let rig = CarGeometry.make(color: "#E10600")
        let ring = CarGeometry.selectionRing()
        let label = SCNNode()
        let revision = UUID()
        var pose = CarSceneRenderer.Pose(id: "TST", rig: rig, ring: ring, label: label)
        pose.transform = matrix_identity_float4x4
        pose.showLabel = true
        pose.selected = true
        consumer.submit(.init(revision: revision, camera: camera, size: CGSize(width: 800, height: 600), controlsVisible: true, poses: [pose]))
        pose.transform?.columns.3.x = 42
        pose.articulation = .init(frontLeft: 0.1, frontRight: 0.12, drsOpen: true)
        consumer.submit(.init(revision: revision, camera: camera, size: CGSize(width: 800, height: 600), controlsVisible: true, poses: [pose]))
        consumer.renderer(renderer, updateAtTime: 1)
        XCTAssertEqual(rig.root.simdPosition.x, 42)
        XCTAssertFalse(label.isHidden)
        XCTAssertFalse(ring.isHidden)
        XCTAssertEqual(rig.frontLeft.simdEulerAngles.y, 0.18, accuracy: 0.0001)
        XCTAssertEqual(rig.rearFlap.simdEulerAngles.x, 0)
        XCTAssertEqual(camera.camera?.orthographicScale, 300)
        consumer.renderer(renderer, updateAtTime: 2)
        XCTAssertEqual(rig.root.simdPosition.x, 42, "An idle render callback must not replay an older snapshot.")
        pose.transform = nil
        consumer.submit(.init(revision: UUID(), camera: camera, size: CGSize(width: 800, height: 600), controlsVisible: false, poses: [pose]))
        consumer.renderer(renderer, updateAtTime: 3)
        XCTAssertTrue(rig.root.isHidden)
        XCTAssertTrue(label.isHidden)
        XCTAssertEqual(label.opacity, 0)
        XCTAssertEqual(ring.opacity, 0)
    }
}

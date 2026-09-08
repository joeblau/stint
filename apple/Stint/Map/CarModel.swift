import SceneKit
import SceneKit.ModelIO
import ModelIO

/// The 2026 Aston Martin AMR26 mesh by Dave Love SketchFab (CC-BY-4.0, see Car-LICENSE.txt), used
/// for its geometry only: the livery is dropped and the bodywork is tinted per team. The mesh is
/// decimated to about 25k triangles and split into a body, the DRS flap, and one front and one rear
/// wheel. Coordinates match the procedural car: meters, X right, Y up, -Z forward, tyres on y = 0,
/// with the wheelbase midpoint at the origin.
enum CarModel {
    static let frontAxle = SIMD3<Float>(0.807, 0.361, -1.691)
    static let rearAxle = SIMD3<Float>(0.773, 0.359, 1.714)
    /// The flap mesh is modelled closed and stored relative to its trailing-edge hinge.
    static let flapHinge = SIMD3<Float>(0, 0.922, 2.181)

    private struct Parts {
        let body: SCNGeometry       // submeshes: paint, carbon
        let flap: SCNGeometry       // submeshes: paint
        let frontWheel: SCNGeometry // submeshes: rubber, hub
        let rearWheel: SCNGeometry  // submeshes: rubber, hub
    }

    private static let parts: Parts? = {
        guard let body = geometry(named: "body"), let flap = geometry(named: "flap"),
              let front = geometry(named: "wheel-front"), let rear = geometry(named: "wheel-rear") else { return nil }
        return Parts(body: body, flap: flap, frontWheel: front, rearWheel: rear)
    }()

    static var isAvailable: Bool { parts != nil }

    /// Loads one OBJ part. Each `usemtl` group becomes a geometry element, in file order.
    static func geometry(named name: String, in bundle: Bundle = .main) -> SCNGeometry? {
        guard let url = bundle.url(forResource: name, withExtension: "obj") else { return nil }
        return geometry(at: url)
    }

    static func geometry(at url: URL) -> SCNGeometry? {
        let asset = MDLAsset(url: url)
        guard let mesh = asset.childObjects(of: MDLMesh.self).first as? MDLMesh else { return nil }
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
        return SCNGeometry(mdlMesh: mesh)
    }

    /// Assembles a car in the team color, or nil when the model files are missing.
    static func make(color: String) -> CarGeometry.Rig? {
        guard let parts else { return nil }
        let paint = CarGeometry.material(PlatformColor(hex: color), metallic: 0.35, roughness: 0.42)
        let carbon = CarGeometry.material(PlatformColor(white: 0.07, alpha: 1), metallic: 0.3, roughness: 0.55)
        let rubber = CarGeometry.material(PlatformColor(white: 0.035, alpha: 1), roughness: 0.92)
        let hub = CarGeometry.material(PlatformColor(white: 0.16, alpha: 1), metallic: 0.8, roughness: 0.45)
        // Left-hand wheels are mirrored copies, which flips their winding.
        rubber.isDoubleSided = true
        hub.isDoubleSided = true

        let root = SCNNode()
        let body = SCNNode(geometry: parts.body.copy() as? SCNGeometry)
        body.name = "chassis"
        body.geometry?.materials = [paint, carbon]
        root.addChildNode(body)

        // Hinge at the trailing edge. The rig closes the flap at -30° and opens it to 0°, so the
        // closed mesh is pre-rotated by +30° to sit in its modelled pose when the hinge is closed.
        let hinge = SCNNode()
        hinge.name = "drs-flap-hinge"
        hinge.simdPosition = flapHinge
        hinge.simdEulerAngles.x = CarGeometry.Rig.closedFlapAngle
        let flap = SCNNode(geometry: parts.flap.copy() as? SCNGeometry)
        flap.geometry?.materials = [paint]
        flap.simdEulerAngles.x = -CarGeometry.Rig.closedFlapAngle
        hinge.addChildNode(flap)
        root.addChildNode(hinge)

        var frontLeft = SCNNode()
        var frontRight = SCNNode()
        for (axle, geometry, front) in [(frontAxle, parts.frontWheel, true), (rearAxle, parts.rearWheel, false)] {
            for side: Float in [-1, 1] {
                let pivot = SCNNode()
                pivot.name = "\(front ? "front" : "rear")-\(side < 0 ? "left" : "right")-wheel"
                pivot.simdPosition = SIMD3(side * axle.x, axle.y, axle.z)
                let wheel = SCNNode(geometry: geometry.copy() as? SCNGeometry)
                wheel.geometry?.materials = [rubber, hub]
                if side < 0 { wheel.simdScale = SIMD3(-1, 1, 1) } // mirror the modelled right-hand wheel
                pivot.addChildNode(wheel)
                root.addChildNode(pivot)
                if front { if side < 0 { frontLeft = pivot } else { frontRight = pivot } }
            }
        }
        return CarGeometry.Rig(root: root, frontLeft: frontLeft, frontRight: frontRight, rearFlap: hinge)
    }
}

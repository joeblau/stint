import SceneKit
import SceneKit.ModelIO
import ModelIO

/// The mini jet flown between race venues. Prefers the bundled Gulfstream G650ER
/// (CC-BY-4.0, see Plane-LICENSE.txt when present); otherwise a procedural stand-in.
/// Convention: meters, X right, Y up, nose toward -Z, centered on the fuselage midpoint.
enum PlaneModel {
    static let cruiseScale: Float = 1

    private static let template: SCNNode? = {
        if let url = Bundle.main.url(forResource: "g650", withExtension: "usdz"),
           let scene = try? SCNScene(url: url) { return scene.rootNode }
        if let url = Bundle.main.url(forResource: "g650", withExtension: "obj") {
            let mesh = MDLAsset(url: url).childObjects(of: MDLMesh.self).first as? MDLMesh
            if let mesh {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
                let geometry = SCNGeometry(mdlMesh: mesh)
                // The mesh ships without materials: a white executive-jet finish.
                let paint = SCNMaterial()
                paint.lightingModel = .physicallyBased
                paint.diffuse.contents = PlatformColor(white: 0.93, alpha: 1)
                paint.metalness.contents = NSNumber(value: 0.5)
                paint.roughness.contents = NSNumber(value: 0.35)
                geometry.materials = [paint]
                return SCNNode(geometry: geometry)
            }
        }
        return nil
    }()

    static var isAvailable: Bool { template != nil }

    /// A detached copy of the jet. The bundled model is normalized to ~30 m long;
    /// the fallback is built at that size directly.
    static func make() -> SCNNode {
        if let template {
            let jet = template.clone()
            normalize(jet)
            // Flight pose/scale belongs to a wrapper so it cannot overwrite asset normalization.
            let root = SCNNode()
            root.addChildNode(jet)
            return root
        }
        return procedural()
    }

    private static func normalize(_ node: SCNNode) {
        let (min, max) = node.boundingBox
        let length = max.z - min.z
        guard length > 0 else { return }
        let scale = 30 / Float(length)
        node.scale = SCNVector3(scale, scale, scale)
        let center = SIMD3<Float>(Float(min.x + max.x), Float(min.y + max.y), Float(min.z + max.z)) / 2
        node.simdPosition = -center * scale
    }

    private static func procedural() -> SCNNode {
        func material(_ white: CGFloat, metallic: CGFloat = 0.6, roughness: CGFloat = 0.35) -> SCNMaterial {
            let material = SCNMaterial()
            material.diffuse.contents = PlatformColor(white: white, alpha: 1)
            material.metalness.contents = NSNumber(value: metallic)
            material.roughness.contents = NSNumber(value: roughness)
            return material
        }
        let white = material(0.92)
        let dark = material(0.1, metallic: 0.2, roughness: 0.6)

        let root = SCNNode()
        let fuselage = SCNCapsule(capRadius: 1.5, height: 24)
        fuselage.materials = [white]
        let body = SCNNode(geometry: fuselage)
        body.eulerAngles.x = .pi / 2 // capsule axis is Y; lay it along Z
        root.addChildNode(body)

        let wing = SCNBox(width: 26, height: 0.25, length: 3.4, chamferRadius: 0.6)
        wing.materials = [white]
        let wings = SCNNode(geometry: wing)
        wings.position = SCNVector3(0, -0.4, 2.5)
        root.addChildNode(wings)

        let stabilizer = SCNBox(width: 8, height: 0.22, length: 1.8, chamferRadius: 0.4)
        stabilizer.materials = [white]
        let tailplane = SCNNode(geometry: stabilizer)
        tailplane.position = SCNVector3(0, 3.4, 11.5)
        root.addChildNode(tailplane)

        let fin = SCNBox(width: 0.25, height: 4.6, length: 2.6, chamferRadius: 0.4)
        fin.materials = [white]
        let tail = SCNNode(geometry: fin)
        tail.position = SCNVector3(0, 1.6, 11.2)
        root.addChildNode(tail)

        for side: Float in [-1, 1] {
            let nacelle = SCNCapsule(capRadius: 0.7, height: 3.6)
            nacelle.materials = [dark]
            let engine = SCNNode(geometry: nacelle)
            engine.eulerAngles.x = .pi / 2
            engine.position = SCNVector3(1.4 * side, 0.5, 8.6)
            root.addChildNode(engine)
        }
        return root
    }
}

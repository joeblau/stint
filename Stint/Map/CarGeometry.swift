import SceneKit

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
#else
import UIKit
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    convenience init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0xFFFFFF
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}

/// Original, procedural open-wheel car. Local coordinates: X right, Y up, -Z forward.
/// Geometry uses approximate meters; no external models or licensed liveries are required.
enum CarGeometry {
    final class Rig {
        let root: SCNNode
        let frontLeft: SCNNode
        let frontRight: SCNNode
        let rearFlap: SCNNode
        static let closedFlapAngle: Float = -.pi / 6
        private var lastDRS: Bool?

        init(root: SCNNode, frontLeft: SCNNode, frontRight: SCNNode, rearFlap: SCNNode) {
            self.root = root
            self.frontLeft = frontLeft
            self.frontRight = frontRight
            self.rearFlap = rearFlap
        }

        func apply(_ pose: CarArticulation, animated: Bool) {
            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.12 : 0
            frontLeft.simdEulerAngles.y = Float(pose.frontLeft)
            frontRight.simdEulerAngles.y = Float(pose.frontRight)
            SCNTransaction.commit()

            let flapAngle: Float = pose.drsOpen ? 0 : Self.closedFlapAngle
            // Do not restart the flap's animation on every telemetry frame.
            if lastDRS != pose.drsOpen || !animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = animated ? 0.22 : 0
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                rearFlap.simdEulerAngles.x = flapAngle
                SCNTransaction.commit()
                lastDRS = pose.drsOpen
            }
        }
    }

    static func make(color: String) -> Rig {
        let root = SCNNode()
        let frontLeft = SCNNode()
        let frontRight = SCNNode()
        let rearFlap = SCNNode()
        let paint = material(PlatformColor(hex: color), metallic: 0.55, roughness: 0.3)
        let carbon = material(PlatformColor(white: 0.055, alpha: 1), metallic: 0.25)
        let rubber = material(PlatformColor(white: 0.025, alpha: 1), roughness: 0.95)
        let silver = material(PlatformColor(white: 0.65, alpha: 1), metallic: 0.9)

        func box(_ width: CGFloat, _ height: CGFloat, _ length: CGFloat,
                 _ x: Float, _ y: Float, _ z: Float, _ material: SCNMaterial, radius: CGFloat = 0.05) {
            let shape = SCNBox(width: width, height: height, length: length, chamferRadius: radius)
            shape.materials = [material]
            let node = SCNNode(geometry: shape)
            node.simdPosition = SIMD3(x, y, z)
            root.addChildNode(node)
        }

        box(1.5, 0.12, 3.5, 0, 0.24, 0.2, carbon) // floor
        box(0.62, 0.48, 2.8, 0, 0.53, 0, paint, radius: 0.22) // monocoque
        box(0.29, 0.2, 1.65, 0, 0.40, -1.62, paint, radius: 0.09) // nose
        box(0.53, 0.40, 1.65, -0.53, 0.43, 0.4, paint, radius: 0.17)
        box(0.53, 0.40, 1.65, 0.53, 0.43, 0.4, paint, radius: 0.17)
        box(1.95, 0.09, 0.42, 0, 0.23, -2.23, carbon) // front wing
        box(1.88, 0.08, 0.15, 0, 0.31, -2.13, paint)
        box(1.65, 0.08, 0.32, 0, 0.83, 1.9, paint) // fixed rear-wing main plane
        box(0.08, 0.70, 0.48, -0.80, 0.73, 2.0, carbon)
        box(0.08, 0.70, 0.48, 0.80, 0.73, 2.0, carbon)
        // Hinge along the trailing edge. Flattening the flap opens the slot above
        // the fixed main plane; the endplates stay attached to the chassis.
        rearFlap.name = "drs-flap-hinge"
        rearFlap.simdPosition = SIMD3(0, 1.06, 2.18)
        rearFlap.simdEulerAngles.x = Rig.closedFlapAngle
        let flap = SCNBox(width: 1.65, height: 0.07, length: 0.38, chamferRadius: 0.02)
        flap.materials = [paint]
        let flapNode = SCNNode(geometry: flap)
        flapNode.simdPosition = SIMD3(0, 0, -0.19)
        rearFlap.addChildNode(flapNode)
        root.addChildNode(rearFlap)
        box(0.25, 0.75, 0.6, 0, 0.7, 0.8, paint, radius: 0.1) // airbox
        box(0.46, 0.13, 0.7, 0, 0.8, -0.35, carbon, radius: 0.06) // cockpit

        for x: Float in [-0.93, 0.93] {
            for z: Float in [-1.45, 1.4] {
                let pivot = z < 0 ? (x < 0 ? frontLeft : frontRight) : SCNNode()
                pivot.name = "\(z < 0 ? "front" : "rear")-\(x < 0 ? "left" : "right")-wheel"
                pivot.simdPosition = SIMD3(x, 0.38, z)
                root.addChildNode(pivot)
                let tire = SCNCylinder(radius: 0.38, height: 0.38)
                tire.radialSegmentCount = 20
                tire.materials = [rubber]
                let wheel = SCNNode(geometry: tire)
                wheel.eulerAngles.z = .pi / 2
                pivot.addChildNode(wheel)
                let hub = SCNCylinder(radius: 0.19, height: 0.39)
                hub.materials = [silver]
                let hubNode = SCNNode(geometry: hub)
                wheel.addChildNode(hubNode)
                box(0.85, 0.05, 0.07, x / 2, 0.35, z, carbon, radius: 0.01)
            }
        }
        let helmet = SCNSphere(radius: 0.17)
        helmet.materials = [material(.white, roughness: 0.4)]
        let driver = SCNNode(geometry: helmet)
        driver.simdPosition = SIMD3(0, 0.9, -0.28)
        root.addChildNode(driver)

        let halo = SCNTorus(ringRadius: 0.28, pipeRadius: 0.035)
        halo.materials = [carbon]
        let haloNode = SCNNode(geometry: halo)
        haloNode.simdPosition = SIMD3(0, 1.0, -0.4)
        root.addChildNode(haloNode)
        box(0.045, 0.30, 0.05, 0, 0.88, -0.67, carbon, radius: 0.01)
        return Rig(root: root, frontLeft: frontLeft, frontRight: frontRight, rearFlap: rearFlap)
    }

    static func selectionRing() -> SCNNode {
        let shape = SCNTorus(ringRadius: 2.9, pipeRadius: 0.035)
        let glow = SCNMaterial()
        glow.diffuse.contents = PlatformColor.white
        glow.emission.contents = PlatformColor(white: 0.7, alpha: 1)
        shape.materials = [glow]
        let node = SCNNode(geometry: shape)
        node.position.y = 0.04
        return node
    }

    static func label(_ driver: Driver) -> SCNNode {
        let root = SCNNode()
        let plate = SCNPlane(width: 43, height: 18)
        plate.cornerRadius = 5
        let background = SCNMaterial()
        background.diffuse.contents = PlatformColor(white: 0.035, alpha: 0.88)
        background.lightingModel = .constant
        plate.materials = [background]
        root.addChildNode(SCNNode(geometry: plate))
        let text = SCNText(string: driver.id, extrusionDepth: 0)
        #if os(macOS)
        text.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        #else
        text.font = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        #endif
        text.flatness = 0.2
        let ink = SCNMaterial()
        ink.diffuse.contents = PlatformColor(hex: driver.color)
        ink.lightingModel = .constant
        text.materials = [ink]
        let letters = SCNNode(geometry: text)
        let (min, max) = letters.boundingBox
        letters.simdPosition = SIMD3(-(Float(min.x) + Float(max.x)) / 2, -(Float(min.y) + Float(max.y)) / 2, 0.2)
        root.addChildNode(letters)
        return root
    }

    private static func material(_ color: PlatformColor, metallic: CGFloat = 0, roughness: CGFloat = 0.65) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.metalness.contents = metallic
        material.roughness.contents = roughness
        material.lightingModel = .physicallyBased
        return material
    }
}

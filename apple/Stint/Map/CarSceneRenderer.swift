import SceneKit

/// Main-thread map projection hands the newest snapshot to SceneKit's render thread.
/// Scene mutations never make map interaction wait for the renderer's scene lock.
final class CarSceneRenderer: NSObject, SCNSceneRendererDelegate {
    struct Pose {
        let id: String
        let rig: CarGeometry.Rig
        let ring: SCNNode
        let label: SCNNode
        var transform: simd_float4x4?
        var labelPosition = SIMD3<Float>.zero
        var selected = false
        var showLabel = false
        var articulation: CarArticulation?
        var animateArticulation = false
    }
    struct Frame {
        let revision: UUID
        let camera: SCNNode
        let size: CGSize
        let controlsVisible: Bool
        let poses: [Pose]
    }
    private let lock = NSLock()
    private var pending: Frame?
    private var revision: UUID?
    private var controlsVisible: Bool?

    func submit(_ frame: Frame) {
        lock.lock()
        pending = frame
        lock.unlock()
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        lock.lock()
        let frame = pending
        pending = nil
        lock.unlock()
        guard let frame else { return }
        let newScene = revision != frame.revision
        let visibilityChanged = newScene || controlsVisible != frame.controlsVisible
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        frame.camera.simdPosition = SIMD3(Float(frame.size.width / 2), Float(frame.size.height / 2), 2_000)
        frame.camera.camera?.orthographicScale = Double(frame.size.height / 2)
        for pose in frame.poses {
            pose.rig.root.isHidden = pose.transform == nil
            pose.label.isHidden = pose.transform == nil || !pose.showLabel
            if let transform = pose.transform {
                pose.rig.root.simdTransform = transform
                pose.label.simdPosition = pose.labelPosition
                pose.ring.isHidden = !pose.selected
                if let articulation = pose.articulation {
                    pose.rig.apply(articulation, animated: pose.animateArticulation)
                }
            }
            if visibilityChanged {
                let opacity: CGFloat = frame.controlsVisible ? 1 : 0
                for node in [pose.label, pose.ring] {
                    if newScene { node.opacity = opacity }
                    else { node.runAction(.fadeOpacity(to: opacity, duration: 0.35), forKey: "controls-visibility") }
                }
            }
        }
        SCNTransaction.commit()
        revision = frame.revision
        controlsVisible = frame.controlsVisible
    }
}

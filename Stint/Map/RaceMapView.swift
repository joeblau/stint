import SwiftUI
import MapKit
import SceneKit

#if os(macOS)
typealias PlatformView = NSView
typealias PlatformRepresentable = NSViewRepresentable
#else
typealias PlatformView = UIView
typealias PlatformRepresentable = UIViewRepresentable
#endif

struct RaceMapView: PlatformRepresentable {
    let session: RaceSession
    let frameTime: Double
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    func makeNSView(context: Context) -> RaceMapSurface { RaceMapSurface(session: session) }
    func updateNSView(_ view: RaceMapSurface, context: Context) { view.reduceMotion = reduceMotion; view.setActive(active); view.update(session: session) }
    #else
    func makeUIView(context: Context) -> RaceMapSurface { RaceMapSurface(session: session) }
    func updateUIView(_ view: RaceMapSurface, context: Context) { view.reduceMotion = reduceMotion; view.setActive(active); view.update(session: session) }
    #endif
}

/// One transparent scene for the whole field. MapKit owns navigation and geographic projection.
/// Each car receives a local tangent basis from MapKit, keeping it attached during pitch/rotation.
final class RaceMapSurface: PlatformView, MKMapViewDelegate {
    let map = MKMapView()
    private let sceneView = PassthroughSceneView()
    private let scene = SCNScene()
    private let camera = SCNNode()
    private var cars: [String: SCNNode] = [:]
    private var carRigs: [String: CarGeometry.Rig] = [:]
    private var lastArticulationTime: Double?
    private var rings: [String: SCNNode] = [:]
    private var labels: [String: SCNNode] = [:]
    private var session: RaceSession
    private var revision: UUID?
    private var cameraRequest: UUID?
    private var satellite: Bool?
    private var tilted: Bool?
    private var positions: [CarPosition] = []
    private var projectedPositions: [String: CGPoint] = [:]
    private var followCamera = FollowCamera()
    private var followedDriverID: String?
    private var lastFollowUpdate: TimeInterval?
    private var lastReplayTime: Double?
    private var lastControlsVisible = true
    private var active = true
    var reduceMotion = false
    private struct CameraTransition {
        let start: MKMapCamera
        var destination: MKMapCamera
        let began: TimeInterval
    }
    private var cameraTransition: CameraTransition?
    private var transitionTimer: Timer?
    private var preparingCamera = false
    private var dayLighting: Bool?
    private var tileWarmer: MapTileWarmer?
    private var appliedMapLighting: Bool?
    private var lightingTransition: LightingTransition?
    private let ambientLight = SCNNode()
    private let sunLight = SCNNode()
    private static let transitionDuration: TimeInterval = 1.8
    private static let lightingTransitionDuration: TimeInterval = 0.8

    /// A day/night crossfade in flight. A second map in the target style loads above the live map,
    /// fades in, and only then does the live map switch styles underneath it.
    private final class LightingTransition {
        enum Phase { case loading, fading, swapping }
        let map = PassthroughMapView()
        let isDay: Bool
        var phase = Phase.loading
        init(isDay: Bool) { self.isDay = isDay }
    }

    func setActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        isHidden = !active
        if !active { finishCameraTransition(); settleLighting() }
        sceneView.isPlaying = active
        sceneView.rendersContinuously = active
    }
    #if os(macOS)
    private var inputMonitor: Any?
    #endif

    #if os(macOS)
    override var isFlipped: Bool { true }
    #endif

    init(session: RaceSession) {
        self.session = session
        super.init(frame: .zero)
        map.delegate = self
        map.showsCompass = false
        map.showsScale = false
        map.showsBuildings = true
        map.pointOfInterestFilter = .excludingAll
        map.isPitchEnabled = true
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        addSubview(map)
        addSubview(sceneView)
        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.rendersContinuously = true
        sceneView.isPlaying = true
        #if os(macOS)
        // The standings provide accessible driver controls; mesh parts are decorative.
        sceneView.setAccessibilityElement(false)
        sceneView.setAccessibilityChildren([])
        sceneView.wantsLayer = true
        sceneView.layer?.isOpaque = false
        let tap = NSClickGestureRecognizer(target: self, action: #selector(selectCar(_:)))
        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        #else
        sceneView.accessibilityElementsHidden = true
        sceneView.isOpaque = false
        sceneView.isUserInteractionEnabled = false
        let tap = UITapGestureRecognizer(target: self, action: #selector(selectCar(_:)))
        tap.cancelsTouchesInView = false
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.cancelsTouchesInView = false
        #endif
        pinch.delegate = self
        map.addGestureRecognizer(pinch)
        map.addGestureRecognizer(tap)
        let lens = SCNCamera()
        lens.usesOrthographicProjection = true
        lens.projectionDirection = .vertical
        lens.zNear = 1
        lens.zFar = 10_000
        lens.wantsHDR = false
        camera.camera = lens
        scene.rootNode.addChildNode(camera)
        sceneView.pointOfView = camera

        let ambient = ambientLight
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 650
        scene.rootNode.addChildNode(ambient)
        let sun = sunLight
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_500
        sun.eulerAngles = SCNVector3(-0.4, -0.5, 0)
        scene.rootNode.addChildNode(sun)

        let warmer = MapTileWarmer()
        warmer.map.frame = bounds
        #if os(macOS)
        addSubview(warmer.map, positioned: .below, relativeTo: map)
        #else
        insertSubview(warmer.map, belowSubview: map)
        #endif
        tileWarmer = warmer
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            warmer.start()
        }
    }

    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        guard let window else { return }
        window.acceptsMouseMovedEvents = true
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseDragged, .rightMouseDown, .scrollWheel, .keyDown, .magnify, .rotate
        ]) { [weak self] event in
            if let self, event.window === self.window { self.session.overlays.reveal() }
            return event
        }
    }

    deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
    }

    override func layout() {
        super.layout()
        layoutSurface()
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSurface()
    }
    #endif

    private func layoutSurface() {
        map.frame = bounds
        sceneView.frame = bounds
        tileWarmer?.map.frame = bounds
        if revision == nil { update(session: session) }
        synchronizeScene()
        session.displayedCamera = map.camera.copy() as? MKMapCamera
    }

    func update(session: RaceSession, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.session = session
        guard bounds.width > 0, bounds.height > 0 else { return }
        let startCamera = map.camera.copy() as! MKMapCamera
        let sourceChanged = revision != session.revision
        let overviewRequested = cameraRequest != session.cameraRequest
        let enteringFollow = session.followsDriver && followedDriverID != session.selectedDriverID
        let tiltChanged = tilted != nil && tilted != session.tilted
        if sourceChanged { finishCameraTransition() }
        if sourceChanged || satellite != session.satellite { settleLighting() }
        preparingCamera = true
        let isDay = session.lightingIsDay
        if dayLighting != isDay { applyLighting(isDay: isDay) }
        if satellite != session.satellite {
            satellite = session.satellite
            map.showsBuildings = !session.satellite
            if session.satellite {
                map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat)
            } else {
                let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
                configuration.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = configuration
            }
        }
        if revision != session.revision {
            revision = session.revision
            resetFollowCamera()
            map.removeOverlays(map.overlays)
            for node in cars.values { node.removeFromParentNode() }
            for node in labels.values { node.removeFromParentNode() }
            cars.removeAll(); labels.removeAll(); rings.removeAll()
            carRigs.removeAll()
            lastArticulationTime = nil
            if let replay = session.replay {
                let coordinates = replay.circuit.map(\.coordinate)
                map.addOverlay(MKPolyline(coordinates: coordinates, count: coordinates.count))
                for recording in replay.recordings {
                    let rig = CarGeometry.make(color: recording.driver.color)
                    let car = rig.root
                    carRigs[recording.driver.id] = rig
                    let ring = CarGeometry.selectionRing()
                    car.addChildNode(ring)
                    cars[recording.driver.id] = car
                    rings[recording.driver.id] = ring
                    scene.rootNode.addChildNode(car)
                    let label = CarGeometry.label(recording.driver)
                    labels[recording.driver.id] = label
                    scene.rootNode.addChildNode(label)
                }
            }
        }
        if cameraRequest != session.cameraRequest {
            cameraRequest = session.cameraRequest
            fitCircuit()
        }
        if tilted != session.tilted {
            tilted = session.tilted
            let next = map.camera.copy() as! MKMapCamera
            next.pitch = session.tilted ? (session.followsDriver ? FollowCamera.chasePitch : 48) : 0
            map.setCamera(next, animated: false)
        }
        var destination = tiltChanged ? map.camera.copy() as! MKMapCamera
            : cameraTransition?.destination ?? map.camera.copy() as! MKMapCamera
        positions = session.positions
        updateCarArticulation()
        if session.followsDriver, let selected = session.selectedPosition {
            let elapsed = lastFollowUpdate.map { now - $0 } ?? 0
            let switchedDriver = followedDriverID != selected.id
            let soughtReplay = lastReplayTime.map { abs(session.time - $0) > 1 || session.time < $0 } ?? true
            let next = destination.copy() as! MKMapCamera
            next.centerCoordinate = selected.point.coordinate
            // Enter follow at MapKit's closest supported zoom and lowest viewing angle.
            // Heading places the camera behind the car, looking along its direction of travel.
            if switchedDriver {
                next.centerCoordinateDistance = FollowCamera.chaseDistance
                next.pitch = FollowCamera.chasePitch
            }
            if session.followsHeading {
                next.heading = followCamera.update(target: selected.heading, elapsed: elapsed,
                                                   snap: switchedDriver || soughtReplay || !session.isPlaying)
            } else {
                followCamera.reset()
            }
            if switchedDriver {
                map.setCamera(next, animated: false)
                if map.camera.pitch < 60 {
                    // Some locations first clamp a new camera to an overhead view.
                    let low = MKMapCamera(lookingAtCenter: selected.point.coordinate, fromDistance: 100,
                                          pitch: FollowCamera.chasePitch, heading: next.heading)
                    map.setCamera(low, animated: false)
                }
                // Clamping an extreme camera request can also shift its target coordinate.
                // Recenter using the accepted distance/pitch so the car stays in view,
                // including when follow is activated while playback is paused.
                let settled = map.camera.copy() as! MKMapCamera
                settled.centerCoordinate = selected.point.coordinate
                destination = settled
            } else {
                destination = next
            }
            followedDriverID = selected.id
            lastFollowUpdate = now
            lastReplayTime = session.time
        } else {
            resetFollowCamera()
        }
        preparingCamera = false
        if !sourceChanged, active, !reduceMotion, enteringFollow || overviewRequested || tiltChanged {
            // Restart from the displayed camera when the user reverses direction mid-flight.
            if overviewRequested && !session.followsDriver {
                destination = map.camera.copy() as! MKMapCamera
            }
            cameraTransition = CameraTransition(start: startCamera, destination: destination, began: now)
            startTransitionTimer()
        } else if cameraTransition != nil, session.followsDriver {
            cameraTransition?.destination = destination
        }
        if cameraTransition != nil {
            advanceCameraTransition(at: now)
        } else if session.followsDriver {
            map.setCamera(destination, animated: false)
        }
        synchronizeScene()
    }

    // MARK: Day/night lighting

    private func applyLighting(isDay: Bool) {
        let firstApplication = dayLighting == nil
        dayLighting = isDay
        cancelLightingTransition()
        if firstApplication || reduceMotion || !active || window == nil || appliedMapLighting == isDay {
            setMapLighting(isDay: isDay, on: map)
            animateSceneLighting(isDay: isDay, duration: 0)
        } else {
            beginLightingTransition(isDay: isDay)
        }
    }

    /// Ends any crossfade immediately and leaves the live map in the requested lighting.
    private func settleLighting() {
        guard lightingTransition != nil, let dayLighting else { return }
        cancelLightingTransition()
        setMapLighting(isDay: dayLighting, on: map)
        animateSceneLighting(isDay: dayLighting, duration: 0)
    }

    private func setMapLighting(isDay: Bool, on target: MKMapView) {
        #if os(macOS)
        target.appearance = NSAppearance(named: isDay ? .aqua : .darkAqua)
        #else
        target.overrideUserInterfaceStyle = isDay ? .light : .dark
        #endif
        if target === map { appliedMapLighting = isDay }
    }

    private func animateSceneLighting(isDay: Bool, duration: TimeInterval) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        ambientLight.light?.intensity = isDay ? 850 : 400
        sunLight.light?.intensity = isDay ? 1_700 : 900
        sunLight.light?.color = PlatformColor(hex: isDay ? "#FFF4DB" : "#ADC8FF")
        SCNTransaction.commit()
    }

    private func beginLightingTransition(isDay: Bool) {
        let transition = LightingTransition(isDay: isDay)
        let overlay = transition.map
        overlay.delegate = self
        overlay.showsCompass = false
        overlay.showsScale = false
        overlay.pointOfInterestFilter = .excludingAll
        overlay.isPitchEnabled = true
        overlay.preferredConfiguration = map.preferredConfiguration.copy() as! MKMapConfiguration
        overlay.showsBuildings = map.showsBuildings
        overlay.addOverlays(map.overlays)
        overlay.frame = bounds
        overlay.setCamera(map.camera.copy() as! MKMapCamera, animated: false)
        setMapLighting(isDay: isDay, on: overlay)
        #if os(macOS)
        overlay.alphaValue = 0
        overlay.setAccessibilityElement(false)
        addSubview(overlay, positioned: .above, relativeTo: map)
        #else
        overlay.alpha = 0
        overlay.isUserInteractionEnabled = false
        overlay.accessibilityElementsHidden = true
        insertSubview(overlay, aboveSubview: map)
        #endif
        lightingTransition = transition
        // Tiles usually arrive within a few hundred milliseconds; never wait on a slow network.
        scheduleLightingStep(after: 1.5, for: transition) { [weak self] in self?.fadeInLightingTransition(transition) }
    }

    private func fadeInLightingTransition(_ transition: LightingTransition) {
        guard lightingTransition === transition, transition.phase == .loading else { return }
        transition.phase = .fading
        let duration = Self.lightingTransitionDuration
        animateSceneLighting(isDay: transition.isDay, duration: duration)
        let swap: () -> Void = { [weak self] in
            guard let self, self.lightingTransition === transition else { return }
            transition.phase = .swapping
            self.setMapLighting(isDay: transition.isDay, on: self.map)
            self.scheduleLightingStep(after: 1.0, for: transition) { [weak self] in self?.finishLightingTransition(transition) }
        }
        #if os(macOS)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            transition.map.animator().alphaValue = 1
        }, completionHandler: swap)
        #else
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseInOut]) {
            transition.map.alpha = 1
        } completion: { _ in swap() }
        #endif
    }

    private func finishLightingTransition(_ transition: LightingTransition) {
        guard lightingTransition === transition else { return }
        cancelLightingTransition()
    }

    private func cancelLightingTransition() {
        guard let transition = lightingTransition else { return }
        transition.map.delegate = nil
        transition.map.removeFromSuperview()
        lightingTransition = nil
    }

    private func scheduleLightingStep(after delay: TimeInterval, for transition: LightingTransition, _ step: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lightingTransition === transition else { return }
            step()
        }
    }

    // MARK: Camera transitions

    private func startTransitionTimer() {
        guard transitionTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.advanceCameraTransition(at: ProcessInfo.processInfo.systemUptime)
        }
        transitionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func advanceCameraTransition(at now: TimeInterval) {
        guard let transition = cameraTransition else { return }
        let progress = reduceMotion ? 1 : (now - transition.began) / Self.transitionDuration
        map.setCamera(MapFlight.camera(from: transition.start, to: transition.destination, progress: progress), animated: false)
        if progress >= 1 { finishCameraTransition() }
    }

    private func finishCameraTransition() {
        if let transition = cameraTransition { map.setCamera(transition.destination, animated: false) }
        cameraTransition = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    private func resetFollowCamera() {
        followCamera.reset()
        followedDriverID = nil
        lastFollowUpdate = nil
        lastReplayTime = nil
    }

    private func fitCircuit() {
        guard let replay = session.replay else { return }
        let rect = replay.circuit.reduce(MKMapRect.null) { rect, point in
            let p = MKMapPoint(point.coordinate)
            return rect.union(MKMapRect(x: p.x, y: p.y, width: 1, height: 1))
        }
        #if os(macOS)
        let insets = NSEdgeInsets(top: 150, left: 120, bottom: 160, right: 120)
        #else
        let insets = UIEdgeInsets(top: 150, left: 80, bottom: 170, right: 80)
        #endif
        // Fit from the same orientation regardless of the current chase heading/pitch.
        let overhead = map.camera.copy() as! MKMapCamera
        overhead.heading = 0
        overhead.pitch = 0
        map.setCamera(overhead, animated: false)
        map.setVisibleMapRect(rect, edgePadding: insets, animated: false)
        let next = map.camera.copy() as! MKMapCamera
        next.heading = 0
        next.pitch = session.tilted ? 48 : 0
        map.setCamera(next, animated: false)
    }

    private func updateCarArticulation() {
        guard lastArticulationTime != session.time, let replay = session.replay else { return }
        let delta = lastArticulationTime.map { session.time - $0 }
        let animated = !reduceMotion && session.isPlaying && delta.map { $0 > 0 && $0 < 0.5 } == true
        for recording in replay.recordings {
            carRigs[recording.driver.id]?.apply(CarArticulation.estimate(recording: recording, at: session.time),
                                               animated: animated)
        }
        lastArticulationTime = session.time
    }

    private func synchronizeScene() {
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        if let overlay = lightingTransition?.map {
            overlay.frame = bounds
            overlay.setCamera(map.camera.copy() as! MKMapCamera, animated: false)
        }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0
        camera.simdPosition = SIMD3(Float(width / 2), Float(height / 2), 2_000)
        // The vertical orthographic span equals the view height: one scene unit per point.
        // Use SceneKit's native projection so its culling volume matches the rendered volume.
        camera.camera?.orthographicScale = Double(height / 2)
        let pitch = Float(map.camera.pitch * .pi / 180)
        projectedPositions.removeAll(keepingCapacity: true)
        for position in positions {
            guard let car = cars[position.id] else { continue }
            let point = map.convert(position.point.coordinate, toPointTo: self)
            guard point.x.isFinite, point.y.isFinite, bounds.insetBy(dx: -80, dy: -80).contains(point) else {
                car.isHidden = true
                labels[position.id]?.isHidden = true
                continue
            }
            car.isHidden = false
            projectedPositions[position.id] = point
            let rightPoint = map.convert(position.point.offset(meters: 10, bearing: position.heading + 90).coordinate, toPointTo: self)
            let backPoint = map.convert(position.point.offset(meters: 10, bearing: position.heading + 180).coordinate, toPointTo: self)
            let eastPoint = map.convert(position.point.offset(meters: 10, bearing: map.camera.heading + 90).coordinate, toPointTo: self)
            let metersToPixels = max(0.001, hypot(eastPoint.x - point.x, eastPoint.y - point.y) / 10)
            // Keep cars legible at circuit scale. This is an intentionally exaggerated model size.
            let factor = Float(max(5.5, metersToPixels) / metersToPixels * session.carScale)
            let yaw = Float((position.heading - map.camera.heading) * .pi / 180)
            let unit = Float(metersToPixels)
            let right = SIMD3(Float(rightPoint.x - point.x) / 10, -Float(rightPoint.y - point.y) / 10,
                              sin(yaw) * sin(pitch) * unit) * factor
            let back = SIMD3(Float(backPoint.x - point.x) / 10, -Float(backPoint.y - point.y) / 10,
                             cos(yaw) * sin(pitch) * unit) * factor
            let up = SIMD3<Float>(0, sin(pitch), cos(pitch)) * unit * factor
            car.simdTransform = simd_float4x4(columns: (
                SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0),
                SIMD4(Float(point.x), Float(height - point.y), 0, 1)))
            rings[position.id]?.isHidden = position.id != session.selectedDriverID
            labels[position.id]?.isHidden = !session.showLabels
            // Keep the label above the actual model when zoomed all the way in.
            let labelOffset = max(29 * Float(session.carScale), unit * factor * 3.2)
            labels[position.id]?.simdPosition = SIMD3(Float(point.x), Float(height - point.y) + labelOffset, 100)
        }
        SCNTransaction.commit()
        if lastControlsVisible != session.overlays.isVisible {
            lastControlsVisible = session.overlays.isVisible
            let opacity: CGFloat = lastControlsVisible ? 1 : 0
            for node in Array(labels.values) + Array(rings.values) {
                node.runAction(.fadeOpacity(to: opacity, duration: 0.35), forKey: "controls-visibility")
            }
        }
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        guard mapView === map, !preparingCamera else { return }
        session.displayedCamera = map.camera.copy() as? MKMapCamera
        if active { synchronizeScene() }
    }

    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard fullyRendered, let transition = lightingTransition else { return }
        if mapView === transition.map, transition.phase == .loading {
            fadeInLightingTransition(transition)
        } else if mapView === map, transition.phase == .swapping {
            finishLightingTransition(transition)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.strokeColor = PlatformColor(hex: StintPalette.redHex).withAlphaComponent(0.65)
        renderer.lineWidth = 3
        renderer.lineJoin = .round
        renderer.lineCap = .round
        return renderer
    }

    #if os(macOS)
    @objc private func handlePinch(_ gesture: NSMagnificationGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed { beginManualZoom() }
    }
    @objc private func selectCar(_ gesture: NSClickGestureRecognizer) { select(at: gesture.location(in: self)) }
    #else
    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began || gesture.state == .changed { beginManualZoom() }
    }
    @objc private func selectCar(_ gesture: UITapGestureRecognizer) { select(at: gesture.location(in: self)) }
    #endif

    private func beginManualZoom() {
        // Hand the displayed camera to MapKit without jumping to the overview or
        // finishing a follow animation that would overwrite the user's pinch.
        cameraTransition = nil
        transitionTimer?.invalidate()
        transitionTimer = nil
        session.followsDriver = false
        followedDriverID = nil
        lastFollowUpdate = nil
        session.overlays.reveal()
    }

    private func select(at point: CGPoint) {
        session.overlays.reveal()
        let nearest = projectedPositions.min {
            hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y)
        }
        if let nearest, hypot(nearest.value.x - point.x, nearest.value.y - point.y) < 32 {
            session.selectedDriverID = nearest.key
        }
    }
}

/// The crossfade map never takes input; gestures keep going to the live map beneath it.
private final class PassthroughMapView: MKMapView {
    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}

#if os(macOS)
extension RaceMapSurface: NSGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: NSGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer) -> Bool { true }
}
#else
extension RaceMapSurface: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#endif

private final class PassthroughSceneView: SCNView {
    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}

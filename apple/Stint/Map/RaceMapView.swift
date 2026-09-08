import SwiftUI
import MapKit
import SceneKit
import os

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
    var playbackEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Snapshot control values so the representable changes even when frameTime is
    // frozen. Holding only the observable session reference can leave a paused
    // native view with identical inputs after driver or appearance changes.
    private let inputs: Inputs
    private struct Inputs: Equatable {
        let revision: UUID
        let cameraRequest: UUID
        let selectedDriverID: String?
        let lighting: RaceLighting
        let satellite: Bool
        let tilted: Bool
        let followsDriver: Bool
        let followsHeading: Bool
        let carScale: Double
        let showLabels: Bool
        let isPlaying: Bool
        let controlsVisible: Bool
    }

    @MainActor init(session: RaceSession, frameTime: Double, active: Bool = true, playbackEnabled: Bool = true) {
        self.session = session
        self.frameTime = frameTime
        self.active = active
        self.playbackEnabled = playbackEnabled
        inputs = Inputs(revision: session.revision, cameraRequest: session.cameraRequest,
                        selectedDriverID: session.selectedDriverID, lighting: session.lighting,
                        satellite: session.satellite, tilted: session.tilted, followsDriver: session.followsDriver,
                        followsHeading: session.followsHeading, carScale: session.carScale,
                        showLabels: session.showLabels, isPlaying: session.isPlaying,
                        controlsVisible: session.overlays.isVisible)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> RaceMapSurface { RaceMapSurface(session: session) }
    func updateNSView(_ view: RaceMapSurface, context: Context) { view.reduceMotion = reduceMotion; view.setActive(active); view.playbackEnabled = playbackEnabled; view.requestUpdate() }
    #else
    func makeUIView(context: Context) -> RaceMapSurface { RaceMapSurface(session: session) }
    func updateUIView(_ view: RaceMapSurface, context: Context) { view.reduceMotion = reduceMotion; view.setActive(active); view.playbackEnabled = playbackEnabled; view.requestUpdate() }
    #endif
}

/// One transparent scene for the whole field. MapKit owns navigation and geographic projection.
/// Each car receives a local tangent basis from MapKit, keeping it attached during pitch/rotation.
final class RaceMapSurface: PlatformView, MKMapViewDelegate {
    let map = MKMapView()
    private let sceneView = PassthroughSceneView(frame: .zero, options: [SCNView.Option.preferredRenderingAPI.rawValue: SCNRenderingAPI.metal.rawValue])
    private let scene = SCNScene()
    private let carRenderer = CarSceneRenderer()
    private let camera = SCNNode()
    private var cars: [String: SCNNode] = [:]
    private var carRigs: [String: CarGeometry.Rig] = [:]
    private var articulationTimes: [String: Double] = [:]
    private var articulations: [String: (pose: CarArticulation, animated: Bool)] = [:]
    private var rings: [String: SCNNode] = [:]
    private var labels: [String: SCNNode] = [:]
    private var session: RaceSession
    private var revision: UUID?
    private var cameraRequest: UUID?
    private var overviewCamera: MKMapCamera?
    private var overviewSize = CGSize.zero
    private var satellite: Bool?
    private var tilted: Bool?
    private var positions: [CarPosition] = []
    private(set) var projectedPositions: [String: CGPoint] = [:]
    private var followCamera = FollowCamera()
    private var followedDriverID: String?
    private var lastFollowUpdate: TimeInterval?
    private var lastReplayTime: Double?
    private var active = true
    var reduceMotion = false
    private struct CameraTransition {
        let start: MKMapCamera
        var destination: MKMapCamera
        let began: TimeInterval
    }
    private var cameraTransition: CameraTransition?
    private let displayClock = DisplayClock()
    private var previousFrame: TimeInterval?
    private var needsUpdate = true
    private var needsProjection = true
    private var projectionScheduled = false
    private var lastSyncedCamera: MKMapCamera?
    private var groundProjection: GroundProjection?
    private var groundProjectionDirty = true
    private(set) var projectionPassCount = 0
    private static let performanceLog = OSLog(subsystem: "com.joeblau.stint", category: .pointsOfInterest)
    var playbackEnabled = true
    private var preparingCamera = false
    private var dayLighting: Bool?
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
        if active { startDisplayClock() }
        else { displayClock.stop(); previousFrame = nil; sceneView.rendersContinuously = false }
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
        sceneView.delegate = carRenderer
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.preferredFramesPerSecond = 60
        sceneView.showsStatistics = ProcessInfo.processInfo.environment["STINT_RENDER_STATS"] == "1"
        sceneView.rendersContinuously = false
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
    }

    required init?(coder: NSCoder) { fatalError("Use init(session:)") }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
        guard let window else { displayClock.stop(); previousFrame = nil; return }
        startDisplayClock()
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
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayClock.stop(); previousFrame = nil }
        else { startDisplayClock() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutSurface()
    }
    #endif

    private func layoutSurface() {
        map.frame = bounds
        sceneView.frame = bounds
        if revision == nil { update(session: session) }
        needsProjection = true
        groundProjectionDirty = true
        session.displayedCamera = map.camera.copy() as? MKMapCamera
    }

    func requestUpdate() {
        needsUpdate = true
        startDisplayClock()
    }

    var isRenderingContinuously: Bool { sceneView.rendersContinuously }

    private func updateRenderingActivity() {
        let animating = active && ((playbackEnabled && session.isPlaying)
                                   || cameraTransition != nil || lightingTransition != nil)
        if sceneView.rendersContinuously != animating { sceneView.rendersContinuously = animating }
    }

    private func startDisplayClock() {
        guard active else { return }
        displayClock.start(in: self) { [weak self] now in self?.displayFrame(at: now) }
    }

    func displayFrame(at now: TimeInterval) {
        guard active else { previousFrame = nil; return }
        os_signpost(.begin, log: Self.performanceLog, name: "Race display frame")
        defer { os_signpost(.end, log: Self.performanceLog, name: "Race display frame") }
        let elapsed = previousFrame.map { max(0, now - $0) } ?? 0
        previousFrame = now
        let playing = playbackEnabled && session.isPlaying
        if playing { session.advanceFrame(by: elapsed) }
        if needsUpdate || playing {
            needsUpdate = false
            update(session: session, now: now)
        } else if cameraTransition != nil {
            advanceCameraTransition(at: now)
        }
        // Consume any projection work not already handled after a native map movement,
        // and re-anchor whenever the live camera moved since the last pass so the cars
        // stay glued to the ground during pans and zooms.
        if needsProjection || cameraChangedSinceSync() { needsProjection = false; synchronizeScene() }
    }

    private func cameraChangedSinceSync() -> Bool {
        guard let last = lastSyncedCamera else { return true }
        let cam = map.camera
        return abs(cam.centerCoordinateDistance - last.centerCoordinateDistance) > 0.05
            || abs(cam.heading - last.heading) > 0.01
            || abs(cam.pitch - last.pitch) > 0.01
            || abs(cam.centerCoordinate.latitude - last.centerCoordinate.latitude) > 0.0000001
            || abs(cam.centerCoordinate.longitude - last.centerCoordinate.longitude) > 0.0000001
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
            overviewCamera = nil
            resetFollowCamera()
            map.removeOverlays(map.overlays)
            for node in cars.values { node.removeFromParentNode() }
            for node in labels.values { node.removeFromParentNode() }
            cars.removeAll(); labels.removeAll(); rings.removeAll()
            carRigs.removeAll()
            articulationTimes.removeAll()
            articulations.removeAll()
            if let replay = session.replay {
                if let track = TrackSurfaceOverlay(points: replay.circuit) {
                    map.addOverlay(track, level: .aboveRoads)
                }
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
        let requestedOverview: MKMapCamera?
        if cameraRequest != session.cameraRequest {
            cameraRequest = session.cameraRequest
            requestedOverview = fittedCircuitCamera()
        } else { requestedOverview = nil }
        if tilted != session.tilted {
            tilted = session.tilted
            let next = map.camera.copy() as! MKMapCamera
            next.pitch = session.tilted ? (session.followsDriver ? FollowCamera.chasePitch : 48) : 0
            map.setCamera(next, animated: false)
        }
        var destination = requestedOverview ?? (tiltChanged ? map.camera.copy() as! MKMapCamera
            : cameraTransition?.destination ?? map.camera.copy() as! MKMapCamera)
        positions = session.replay?.recordings.map { $0.position(at: session.renderTime) } ?? []
        if session.followsDriver, let selected = positions.first(where: { $0.id == session.selectedDriverID }) {
            let elapsed = lastFollowUpdate.map { now - $0 } ?? 0
            let switchedDriver = followedDriverID != selected.id
            let soughtReplay = lastReplayTime.map { abs(session.renderTime - $0) > 1 || session.renderTime < $0 } ?? true
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
            lastReplayTime = session.renderTime
        } else {
            resetFollowCamera()
        }
        preparingCamera = false
        if !sourceChanged, active, !reduceMotion, enteringFollow || overviewRequested || tiltChanged {
            // Restart from the displayed camera when the user reverses direction mid-flight.
            cameraTransition = CameraTransition(start: startCamera, destination: destination, began: now)
            startDisplayClock()
        } else if cameraTransition != nil, session.followsDriver {
            cameraTransition?.destination = destination
        }
        if cameraTransition != nil {
            advanceCameraTransition(at: now)
        } else if session.followsDriver || overviewRequested {
            map.setCamera(destination, animated: false)
        }
        if sourceChanged || overviewRequested || tiltChanged || session.followsDriver || cameraTransition != nil {
            groundProjectionDirty = true
        }
        needsProjection = true
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
        updateRenderingActivity()
        startDisplayClock()
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
        updateRenderingActivity()
    }

    private func scheduleLightingStep(after delay: TimeInterval, for transition: LightingTransition, _ step: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.lightingTransition === transition else { return }
            step()
        }
    }

    // MARK: Camera transitions

    func advanceCameraTransition(at now: TimeInterval) {
        guard let transition = cameraTransition else { return }
        let progress = reduceMotion ? 1 : (now - transition.began) / Self.transitionDuration
        map.setCamera(MapFlight.camera(from: transition.start, to: transition.destination, progress: progress), animated: false)
        needsProjection = true
        groundProjectionDirty = true
        if progress >= 1 { finishCameraTransition() }
    }

    private func finishCameraTransition() {
        if let transition = cameraTransition { map.setCamera(transition.destination, animated: false) }
        cameraTransition = nil
        updateRenderingActivity()
    }

    private func resetFollowCamera() {
        followCamera.reset()
        followedDriverID = nil
        lastFollowUpdate = nil
        lastReplayTime = nil
    }

    private func fittedCircuitCamera() -> MKMapCamera? {
        if let overviewCamera, overviewSize == bounds.size {
            let destination = overviewCamera.copy() as! MKMapCamera
            destination.pitch = session.tilted ? 48 : 0
            return destination
        }
        guard let replay = session.replay else { return nil }
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
        // Reuse the fitted destination when leaving follow: fitting the live map
        // on every click briefly jumps through multiple cameras and starts tile loads.
        overviewCamera = map.camera.copy() as? MKMapCamera
        overviewSize = bounds.size
        return overviewCamera
    }

    private func updateCarArticulation() {
        let time = session.renderTime
        guard let replay = session.replay else { return }
        for recording in replay.recordings where projectedPositions[recording.driver.id] != nil {
            let id = recording.driver.id
            guard articulationTimes[id] != time else { continue }
            let delta = articulationTimes[id].map { time - $0 }
            let animated = !reduceMotion && session.isPlaying && delta.map { $0 > 0 && $0 < 0.5 } == true
            if animated, let delta, delta < 1.0 / 20 { continue }
            articulations[id] = (CarArticulation.estimate(recording: recording, at: time), animated)
            articulationTimes[id] = time
        }
    }

    private func synchronizeScene() {
        os_signpost(.begin, log: Self.performanceLog, name: "Project cars")
        defer { os_signpost(.end, log: Self.performanceLog, name: "Project cars") }
        projectionPassCount += 1
        let width = bounds.width
        let height = bounds.height
        guard width > 0, height > 0 else { return }
        if let overlay = lightingTransition?.map {
            overlay.frame = bounds
            overlay.setCamera(map.camera.copy() as! MKMapCamera, animated: false)
        }
        let mapCamera = map.camera
        if groundProjectionDirty || groundProjection == nil {
            groundProjectionDirty = false
            let origin = MKMapPoint(mapCamera.centerCoordinate)
            let meters = min(1_000, max(10, mapCamera.centerCoordinateDistance * 0.15))
            let extent = meters * MKMapPointsPerMeterAtLatitude(mapCamera.centerCoordinate.latitude)
            let corners = GroundProjection.samplePoints(origin: origin, extent: extent).map {
                map.convert($0.coordinate, toPointTo: map)
            }
            groundProjection = GroundProjection(origin: origin, extent: extent, corners: corners)
        }
        func project(_ point: GeoPoint) -> CGPoint {
            groundProjection?.project(point) ?? map.convert(point.coordinate, toPointTo: map)
        }
        let pitch = Float(mapCamera.pitch * .pi / 180)
        let mapHeading = mapCamera.heading
        let visibleBounds = bounds.insetBy(dx: -80, dy: -80)
        let selectedID = session.selectedDriverID
        let showLabels = session.showLabels
        let carScale = session.carScale
        projectedPositions.removeAll(keepingCapacity: true)
        var poses: [CarSceneRenderer.Pose] = []
        poses.reserveCapacity(positions.count)
        for position in positions {
            guard let rig = carRigs[position.id], let ring = rings[position.id], let label = labels[position.id] else { continue }
            var pose = CarSceneRenderer.Pose(id: position.id, rig: rig, ring: ring, label: label)
            // Anchor the contact point with MapKit itself. The cached homography
            // is only used for the local orientation, never the car's screen position.
            let point = map.convert(position.point.coordinate, toPointTo: map)
            guard point.x.isFinite, point.y.isFinite, visibleBounds.contains(point) else {
                poses.append(pose)
                continue
            }
            projectedPositions[position.id] = point
            func tangent(bearing: Double) -> CGVector {
                if let groundProjection { return groundProjection.tangent(at: position.point, bearing: bearing) }
                let a = project(position.point.offset(meters: 0.5, bearing: bearing + 180))
                let b = project(position.point.offset(meters: 0.5, bearing: bearing))
                return CGVector(dx: b.x - a.x, dy: b.y - a.y)
            }
            let rightTangent = tangent(bearing: position.heading + 90)
            let backTangent = tangent(bearing: position.heading + 180)
            let eastTangent = tangent(bearing: mapHeading + 90)
            guard [rightTangent.dx, rightTangent.dy, backTangent.dx, backTangent.dy,
                   eastTangent.dx, eastTangent.dy].allSatisfy(\.isFinite) else {
                poses.append(pose)
                continue
            }
            let metersToPixels = max(0.001, hypot(eastTangent.dx, eastTangent.dy))
            // Keep cars legible at circuit scale. This is an intentionally exaggerated model size.
            let factor = Float(max(5.5, metersToPixels) / metersToPixels * carScale)
            let yaw = Float((position.heading - mapHeading) * .pi / 180)
            let unit = Float(metersToPixels)
            let right = SIMD3(Float(rightTangent.dx), -Float(rightTangent.dy),
                              sin(yaw) * sin(pitch) * unit) * factor
            let back = SIMD3(Float(backTangent.dx), -Float(backTangent.dy),
                             cos(yaw) * sin(pitch) * unit) * factor
            let up = SIMD3<Float>(0, sin(pitch), cos(pitch)) * unit * factor
            pose.transform = simd_float4x4(columns: (
                SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0),
                SIMD4(Float(point.x), Float(height - point.y), 0, 1)))
            pose.selected = position.id == selectedID
            pose.showLabel = showLabels
            // Keep the label above the actual model when zoomed all the way in.
            let labelOffset = max(29 * Float(carScale), unit * factor * 3.2)
            pose.labelPosition = SIMD3(Float(point.x), Float(height - point.y) + labelOffset, 100)
            poses.append(pose)
        }
        updateCarArticulation()
        for index in poses.indices {
            let id = poses[index].id
            poses[index].articulation = articulations[id]?.pose
            poses[index].animateArticulation = articulations[id]?.animated ?? false
        }
        carRenderer.submit(.init(revision: session.revision, camera: camera, size: bounds.size,
                                 controlsVisible: session.overlays.isVisible, poses: poses))
        lastSyncedCamera = mapCamera.copy() as? MKMapCamera
        updateRenderingActivity()
        #if os(macOS)
        sceneView.needsDisplay = true
        #else
        sceneView.setNeedsDisplay()
        #endif
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        guard mapView === map, !preparingCamera else { return }
        session.displayedCamera = map.camera.copy() as? MKMapCamera
        guard active else { return }
        needsProjection = true
        groundProjectionDirty = true
        // A gesture can move MapKit after our display-link callback. Publish its
        // new anchors in this run-loop turn rather than waiting another frame.
        // Coalesce callbacks; the display tick refines with the freshest camera.
        guard !projectionScheduled else { return }
        projectionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.projectionScheduled = false
            guard self.active, self.needsProjection else { return }
            self.needsProjection = false
            self.synchronizeScene()
        }
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
        guard let track = overlay as? TrackSurfaceOverlay else { return MKOverlayRenderer(overlay: overlay) }
        return TrackSurfaceRenderer(track: track)
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

/// The bundled paths have no surveyed widths. Start with a uniform 12-meter surface.
private final class TrackSurfaceOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let points: [MKMapPoint]
    let width: CGFloat
    let edgeWidth: CGFloat

    init?(points: [GeoPoint]) {
        guard points.count >= 3, points.allSatisfy(\.isValid) else { return nil }
        var coordinates = points.map(\.coordinate)
        if points.first != points.last { coordinates.append(coordinates[0]) }
        let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
        coordinate = line.coordinate
        self.points = coordinates.map(MKMapPoint.init)
        let unitsPerMeter = MKMapPointsPerMeterAtLatitude(coordinate.latitude)
        width = 12 * unitsPerMeter
        edgeWidth = 0.2 * unitsPerMeter
        boundingMapRect = line.boundingMapRect.insetBy(dx: -width, dy: -width)
        super.init()
    }
}

private final class TrackSurfaceRenderer: MKOverlayRenderer {
    private let trackPath = CGMutablePath()
    private let trackWidth: CGFloat
    private let edgeWidth: CGFloat
    private let asphalt = CGColor(gray: 0.19, alpha: 1)
    private let edge = CGColor(gray: 0.87, alpha: 1)

    init(track: TrackSurfaceOverlay) {
        trackWidth = track.width
        edgeWidth = track.edgeWidth
        super.init(overlay: track)
        for (index, mapPoint) in track.points.enumerated() {
            let local = point(for: mapPoint)
            if index == 0 { trackPath.move(to: local) } else { trackPath.addLine(to: local) }
        }
        trackPath.closeSubpath()
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        context.saveGState()
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Physical map-space widths stay attached to the ground as the camera zooms or tilts.
        context.addPath(trackPath)
        context.setStrokeColor(edge)
        context.setLineWidth(trackWidth)
        context.strokePath()
        context.addPath(trackPath)
        context.setStrokeColor(asphalt)
        context.setLineWidth(trackWidth - 2 * edgeWidth)
        context.strokePath()
        context.restoreGState()
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

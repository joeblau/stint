import SwiftUI
import MapKit
import SceneKit
import simd

struct SeasonGlobeView: PlatformRepresentable {
    let active: Bool
    let flight: MapFlight?
    let onFlightComplete: () -> Void
    let selected: Int?
    let overviewRequest: UUID
    var flyoverRequest = UUID()
    let now: Date
    let onSelect: (SeasonRace) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    func makeNSView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateNSView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, reduceMotion: reduceMotion, flyover: flyoverRequest, onComplete: onFlightComplete) }
    #else
    func makeUIView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateUIView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, reduceMotion: reduceMotion, flyover: flyoverRequest, onComplete: onFlightComplete) }
    #endif
}

#if os(macOS)
private typealias VenueButton = NSButton
#else
private typealias VenueButton = UIButton
#endif

/// Screen overlays preserve MapKit's globe. Native overlays and coordinate conversion
/// use a flat projection at world scale, so world-scale routes use a spherical camera.
final class SeasonGlobeSurface: PlatformView, MKMapViewDelegate {
    let map = MKMapView()
    private let routesLayer = CALayer()
    private let flownTrailLayer = CAShapeLayer()
    var projectedTrailEnd: CGPoint? { flownTrailLayer.path?.isEmpty == false ? flownTrailLayer.path?.currentPoint : nil }
    private(set) var projectedJetPosition: CGPoint?
    private var routes: [(points: [GlobeVertex], layer: CAShapeLayer, destination: SeasonRace)] = []
    private var markerButtons: [VenueButton] = []
    private var cityLabels: [CATextLayer] = []
    private var markerGroups: [[SeasonRace]] = []
    private var lastOverview: UUID?
    private var selected: Int?
    private var now = Date()
    private let onSelect: (SeasonRace) -> Void
    private var active = false
    private var needsRedraw = true
    private let displayClock = DisplayClock()
    private var currentFlight: (request: MapFlight, start: MKMapCamera, began: TimeInterval)?
    private var lastFlightID: UUID?
    private var onFlightComplete: (() -> Void)?
    private var flightStyleIsGlobe = true
    private var markerSignatures: [UInt64] = Array(repeating: 0, count: Season2026.races.count)
    private var projection: GlobeProjection.Camera?
    private let venues = Season2026.races.map { (race: $0, vertex: GlobeVertex($0.point.coordinate)) }
    private let sceneView = PassthroughSceneView()
    private let scene = SCNScene()
    private let sceneCamera = SCNNode()
    private var planeNode: SCNNode?
    struct PlaneFlight {
        let itinerary: GlobeItinerary
        let began: TimeInterval
        let departureCamera: MKMapCamera
        let cameraDistance: Double
        let departureDuration: Double
    }
    private(set) var planeFlight: PlaneFlight?
    private(set) var planePosition: GlobeItinerary.Position?
    /// The last trip flown, kept highlighted on the route lines until the next selection.
    private var flownItinerary: GlobeItinerary?
    private var reduceMotion = false
    /// The cinematic pass over the selected circuit, started by a second click on its pin.
    private var flyover: (pass: TrackFlyover, began: TimeInterval, start: MKMapCamera)?
    private var lastFlyoverRequest: UUID?
    var isFlyingOver: Bool { flyover != nil }



    init(onSelect: @escaping (SeasonRace) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        isHidden = true
        #if os(macOS)
        wantsLayer = true
        #endif
        map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = self
        addSubview(map)
        sceneView.scene = scene
        sceneView.backgroundColor = .clear
        sceneView.antialiasingMode = .multisampling4X
        sceneView.rendersContinuously = false
        sceneView.preferredFramesPerSecond = 60
        sceneView.isPlaying = true
        sceneView.isHidden = true
        #if os(macOS)
        sceneView.wantsLayer = true
        sceneView.layer?.isOpaque = false
        sceneView.layer?.zPosition = 3
        sceneView.setAccessibilityElement(true)
        sceneView.setAccessibilityRole(.image)
        sceneView.setAccessibilityLabel("Gulfstream G650 in flight")
        sceneView.setAccessibilityIdentifier("calendar-jet")
        #else
        sceneView.isOpaque = false
        sceneView.isUserInteractionEnabled = false
        sceneView.layer.zPosition = 3
        sceneView.isAccessibilityElement = true
        sceneView.accessibilityLabel = "Gulfstream G650 in flight"
        sceneView.accessibilityIdentifier = "calendar-jet"
        #endif
        addSubview(sceneView)
        let lens = SCNCamera()
        lens.usesOrthographicProjection = true
        lens.projectionDirection = .vertical
        lens.zNear = 1
        lens.zFar = 10_000
        sceneCamera.camera = lens
        scene.rootNode.addChildNode(sceneCamera)
        sceneView.pointOfView = sceneCamera
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 700
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 1_200
        sun.eulerAngles = SCNVector3(-0.5, -0.6, 0)
        scene.rootNode.addChildNode(sun)
        #if os(macOS)
        layer?.addSublayer(routesLayer)
        #else
        layer.addSublayer(routesLayer)
        #endif
        routesLayer.zPosition = 1
        for (a, b) in zip(Season2026.races, Season2026.races.dropFirst()) {
            let points = GlobeFlight(from: a.point.coordinate, to: b.point.coordinate).coordinates()
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineWidth = 1.6
            shape.lineCap = .round
            routesLayer.addSublayer(shape)
            routes.append((points.map(GlobeVertex.init), shape, b))
        }
        flownTrailLayer.fillColor = nil
        flownTrailLayer.strokeColor = PlatformColor(hex: StintPalette.redHex).withAlphaComponent(0.95).cgColor
        flownTrailLayer.lineWidth = 2.4
        flownTrailLayer.lineCap = .round
        flownTrailLayer.lineJoin = .round
        routesLayer.addSublayer(flownTrailLayer)
        for index in Season2026.races.indices {
            #if os(macOS)
            let button = NSButton(title: "", target: self, action: #selector(handleVenueButton(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 14
            button.layer?.zPosition = 2
            #else
            let button = UIButton(type: .custom)
            button.addTarget(self, action: #selector(handleVenueButton(_:)), for: .touchUpInside)
            button.titleLabel?.font = .systemFont(ofSize: 11, weight: .bold)
            button.layer.cornerRadius = 14
            button.layer.zPosition = 2
            #endif
            button.tag = index
            button.isHidden = true
            markerButtons.append(button)
            addSubview(button)
            let label = CATextLayer()
            label.alignmentMode = .center
            label.cornerRadius = 4
            label.isHidden = true
            routesLayer.addSublayer(label)
            cityLabels.append(label)
        }
    }

    private func setActive(_ value: Bool) {
        guard active != value else { return }
        active = value
        isHidden = !value
        if value {
            needsRedraw = true
            startDisplayClock()
        } else {
            displayClock.stop()
            cancelPlaneFlight()
        }
    }

    private func startDisplayClock() {
        guard active else { return }
        displayClock.start(in: self) { [weak self] now in self?.displayFrame(at: now) }
    }

    #if os(macOS)
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { displayClock.stop() } else { startDisplayClock() }
    }
    #else
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { displayClock.stop() } else { startDisplayClock() }
    }
    #endif

    func displayFrame(at now: TimeInterval) {
        guard active else { return }
        if let flyover {
            let elapsed = now - flyover.began
            map.setCamera(flyover.pass.camera(at: elapsed, from: flyover.start), animated: false)
            needsRedraw = true
            if elapsed >= flyover.pass.duration { cancelFlyover() }
        }
        if let flight = currentFlight {
            let progress = min(1, (now - flight.began) / max(0.001, flight.request.duration))
            let camera = MapFlight.camera(from: flight.start, to: flight.request.destination, progress: progress)
            applyStyle(satellite: flight.request.satellite, day: flight.request.day,
                       globe: camera.centerCoordinateDistance > 2_000_000)
            map.setCamera(camera, animated: false)
            needsRedraw = true
            if progress >= 1 {
                currentFlight = nil
                onFlightComplete?()
            }
        }
        if let plane = planeFlight {
            applyStyle(satellite: true, day: false, globe: plane.cameraDistance > 2_000_000)
            let elapsed = max(0, now - plane.began)
            let travelTime = max(0, elapsed - plane.departureDuration)
            if elapsed < plane.departureDuration, let departure = plane.itinerary.legs.first?.from {
                let target = MKMapCamera(lookingAtCenter: departure, fromDistance: plane.cameraDistance, pitch: 0, heading: 0)
                map.setCamera(MapFlight.camera(from: plane.departureCamera, to: target,
                                               progress: elapsed / plane.departureDuration), animated: false)
                needsRedraw = true
            } else if let position = plane.itinerary.position(at: travelTime) {
                // One distance/time sample controls both plane and camera. No independent camera tween.
                map.setCamera(MKMapCamera(lookingAtCenter: position.coordinate, fromDistance: plane.cameraDistance,
                                          pitch: 0, heading: 0), animated: false)
                planePosition = position
                positionPlane(position)
                needsRedraw = true
                if travelTime >= plane.itinerary.durationSeconds { landPlane() }
            }
        }
        if needsRedraw { needsRedraw = false; drawRoutes() }
    }

    /// Only neighboring schedule entries get a jet flight, in either direction.
    @discardableResult
    private func startPlaneFlight(from origin: SeasonRace, to destination: SeasonRace) -> Bool {
        guard let start = Season2026.races.firstIndex(where: { $0.id == origin.id }),
              let end = Season2026.races.firstIndex(where: { $0.id == destination.id }),
              abs(start - end) == 1 else { return false }
        guard !reduceMotion || ProcessInfo.processInfo.environment["STINT_FORCE_FLIGHT"] == "1" else { return false }
        var itinerary = GlobeItinerary.alongCalendar(from: origin, to: destination)
        let redirected = planeFlight != nil && planePosition != nil
        if let position = planePosition, redirected {
            // Redirect mid-air: the new trip departs from where the jet is now.
            itinerary = .direct(from: position.coordinate, to: destination.point.coordinate)
        }
        guard itinerary.distanceKm > 0.001 else { return false }
        flownItinerary = itinerary
        if planeNode == nil {
            let node = PlaneModel.make()
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            planeNode = node
        }
        planeNode?.removeAllActions()
        planeNode?.opacity = 1
        // Asset loading must not consume the flight clock, particularly on short routes.
        let camera = map.camera.copy() as! MKMapCamera
        let distance = redirected ? camera.centerCoordinateDistance
            : min(5_000_000, max(600_000, (itinerary.legs.first?.distanceKm ?? 0) * 2_000))
        planeFlight = PlaneFlight(itinerary: itinerary, began: ProcessInfo.processInfo.systemUptime,
                                  departureCamera: camera, cameraDistance: distance,
                                  departureDuration: redirected ? 0 : 0.8)
        if !redirected { planePosition = nil; sceneView.isHidden = true }
        sceneView.rendersContinuously = true
        startDisplayClock()
        return true
    }

    private func landPlane() {
        planeFlight = nil
        planeNode?.isHidden = true
        sceneView.isHidden = true
        sceneView.rendersContinuously = false
        needsRedraw = true
    }

    private func cancelPlaneFlight() {
        landPlane()
        planePosition = nil
        flownItinerary = nil
        projectedJetPosition = nil
        flownTrailLayer.path = nil
    }

    private func positionPlane(_ position: GlobeItinerary.Position) {
        guard let node = planeNode, bounds.width > 0, bounds.height > 0 else { return }
        projection = GlobeProjection.Camera(center: map.camera.centerCoordinate,
                                            distance: map.camera.centerCoordinateDistance, size: bounds.size)
        guard let point = projectOnScreen(position.coordinate) else {
            projectedJetPosition = nil
            node.isHidden = true
            return
        }
        projectedJetPosition = point
        let altitude = position.altitude
        let climb = Float(cos(position.legProgress * .pi) * 0.18)
        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        SCNTransaction.animationDuration = 0
        sceneView.isHidden = false
        node.isHidden = false
        node.opacity = max(0, min(1, min(position.progress / 0.05, (1 - position.progress) / 0.08)))
        node.simdPosition = SIMD3(Float(point.x), Float(bounds.height - point.y), Float(60 + altitude * 26))
        // Nose follows the north-up map bearing; show the top with a little pitch for depth.
        node.simdOrientation = simd_quatf(angle: -Float(position.heading * .pi / 180), axis: SIMD3(0, 0, 1))
            * simd_quatf(angle: .pi / 2 - 0.25 - climb, axis: SIMD3(1, 0, 0))
        // About 60 points long at cruise so the jet reads at globe scale.
        node.simdScale = SIMD3(repeating: Float(1.6 + altitude * 0.6))
        sceneCamera.simdPosition = SIMD3(Float(bounds.width / 2), Float(bounds.height / 2), 2_000)
        sceneCamera.camera?.orthographicScale = Double(bounds.height / 2)
        SCNTransaction.commit()
        #if os(macOS)
        sceneView.needsDisplay = true
        #else
        sceneView.setNeedsDisplay()
        #endif
    }

    private func projectOnScreen(_ coordinate: CLLocationCoordinate2D) -> CGPoint? {
        if map.camera.centerCoordinateDistance < 2_000_000 {
            let point = map.convert(coordinate, toPointTo: self)
            return point.x.isFinite && point.y.isFinite ? point : nil
        }
        if projection == nil {
            projection = GlobeProjection.Camera(center: map.camera.centerCoordinate,
                                                distance: map.camera.centerCoordinateDistance, size: bounds.size)
        }
        return projection?.point(GlobeVertex(coordinate).vector)
    }

    private func applyStyle(satellite: Bool, day: Bool, globe: Bool) {
        #if os(macOS)
        let appearance = (!globe && day) ? NSAppearance.Name.aqua : .darkAqua
        if map.appearance?.name != appearance { map.appearance = NSAppearance(named: appearance) }
        #else
        let style: UIUserInterfaceStyle = (!globe && day) ? .light : .dark
        if map.overrideUserInterfaceStyle != style { map.overrideUserInterfaceStyle = style }
        #endif
        guard flightStyleIsGlobe != globe else { return }
        flightStyleIsGlobe = globe
        if globe { map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic) }
        else if satellite { map.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .flat) }
        else { map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted) }
        map.showsBuildings = !globe && !satellite
    }

    required init?(coder: NSCoder) { fatalError("Use init(onSelect:)") }
    #if os(macOS)
    override var isFlipped: Bool { true }
    override func layout() { super.layout(); layoutMap() }
    #else
    override func layoutSubviews() { super.layoutSubviews(); layoutMap() }
    #endif

    private func layoutMap() {
        map.frame = bounds
        routesLayer.frame = bounds
        sceneView.frame = bounds
        needsRedraw = true
    }

    func update(selected: Int?, overview: UUID, now: Date, active: Bool, flight: MapFlight?, reduceMotion: Bool,
                flyover flyoverRequest: UUID? = nil, onComplete: @escaping () -> Void) {
        setActive(active)
        onFlightComplete = onComplete
        self.reduceMotion = reduceMotion
        // The card's "Fly over circuit" button changes this token; the first value seen is the baseline.
        if let flyoverRequest {
            if lastFlyoverRequest == nil {
                lastFlyoverRequest = flyoverRequest
            } else if lastFlyoverRequest != flyoverRequest {
                lastFlyoverRequest = flyoverRequest
                if currentFlight == nil, let race = Season2026.races.first(where: { $0.id == selected }) { startFlyover(race) }
            }
        }
        if !Calendar.current.isDate(self.now, inSameDayAs: now) { needsRedraw = true }
        self.now = now
        if let flight, lastFlightID != flight.id {
            cancelPlaneFlight()
            cancelFlyover()
            lastFlightID = flight.id
            let start = flight.start ?? map.camera.copy() as! MKMapCamera
            // Match the race map's style before the first frame so the swap reads as one camera move.
            applyStyle(satellite: flight.satellite, day: flight.day,
                       globe: start.centerCoordinateDistance > 2_000_000)
            map.setCamera(start, animated: false)
            currentFlight = (flight, start, ProcessInfo.processInfo.systemUptime)
        }
        if lastOverview != overview {
            lastOverview = overview
            cancelPlaneFlight()
            cancelFlyover()
            if currentFlight == nil { map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: 20, longitude: 15),
                                     fromDistance: 40_000_000, pitch: 0, heading: 0), animated: false)
            }
        }
        if currentFlight == nil, self.selected != selected {
            selectRace(selected)
        }
        if reduceMotion, planeFlight != nil,
           ProcessInfo.processInfo.environment["STINT_FORCE_FLIGHT"] != "1" {
            let destination = planeFlight?.itinerary.legs.last?.to
            cancelPlaneFlight()
            if let destination {
                map.setCamera(MKMapCamera(lookingAtCenter: destination, fromDistance: 4_000_000,
                                         pitch: 0, heading: 0), animated: false)
            }
        }
    }

    /// Schedule rows fly the jet from the previous selection; pins select directly.
    private func selectRace(_ selected: Int?, byJet: Bool = true) {
        let previous = self.selected
        self.selected = selected
        needsRedraw = true
        cancelFlyover()
        if let race = Season2026.races.first(where: { $0.id == selected }) {
            var flying = false
            if byJet, active, let previous, let origin = Season2026.races.first(where: { $0.id == previous }) {
                flying = startPlaneFlight(from: origin, to: race)
            } else {
                flownItinerary = nil
            }
            if !flying {
                cancelPlaneFlight()
                map.setCamera(MKMapCamera(lookingAtCenter: race.point.coordinate,
                                         fromDistance: byJet && previous != nil ? 6_000 : previous == nil ? 4_000_000 : 300_000,
                                         pitch: 0, heading: 0), animated: !reduceMotion)
            }
        } else {
            cancelPlaneFlight()
        }
    }

    /// A pin click selects the venue without flying the jet; clicking the selected pin again
    /// starts a cinematic pass over its circuit.
    func selectVenue(_ race: SeasonRace) {
        guard currentFlight == nil else { return }
        if selected != race.id {
            selectRace(race.id, byJet: false)
        } else if planeFlight == nil {
            startFlyover(race)
        }
        onSelect(race)
        needsRedraw = true
    }

    /// Settle above the circuit, chase one lap along the centerline, then pull back.
    func startFlyover(_ race: SeasonRace) {
        guard let circuit = try? race.circuit.loadCircuit() else { return }
        cancelPlaneFlight()
        let pass = TrackFlyover(circuit: circuit)
        if reduceMotion, ProcessInfo.processInfo.environment["STINT_FORCE_FLIGHT"] != "1" {
            let overview = pass.overviewCamera
            map.setCamera(MKMapCamera(lookingAtCenter: overview.centerCoordinate, fromDistance: overview.centerCoordinateDistance,
                                      pitch: 0, heading: 0), animated: false)
            needsRedraw = true
            return
        }
        map.isPitchEnabled = true
        flyover = (pass, ProcessInfo.processInfo.systemUptime, map.camera.copy() as! MKMapCamera)
        setMapAccessibilityLabel("Flying over \(race.circuit.title)")
        needsRedraw = true
        startDisplayClock()
    }

    private func cancelFlyover() {
        flyover = nil
        setMapAccessibilityLabel(nil)
    }

    /// Announces the pass on the selected pin for assistive technology and UI tests while it runs.
    private func setMapAccessibilityLabel(_ label: String?) {
        for (index, group) in markerGroups.enumerated() where group.contains(where: { $0.id == selected }) {
            #if os(macOS)
            markerButtons[index].setAccessibilityValue(label)
            #else
            markerButtons[index].accessibilityValue = label
            #endif
        }
    }

    @objc private func handleVenueButton(_ sender: VenueButton) {
        guard currentFlight == nil, markerGroups.indices.contains(sender.tag) else { return }
        let races = markerGroups[sender.tag]
        if races.count == 1 {
            selectVenue(races[0])
        }
        else {
            let latitude = races.map(\.point.latitude).reduce(0, +) / Double(races.count)
            let longitude = races.map(\.point.longitude).reduce(0, +) / Double(races.count)
            map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: latitude, longitude: longitude),
                                     fromDistance: max(300_000, map.camera.centerCoordinateDistance * 0.22),
                                     pitch: 0, heading: 0), animated: true)
        }
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) { needsRedraw = true }
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) { needsRedraw = true }

    private func projected(_ vertex: GlobeVertex) -> CGPoint? {
        let distance = map.camera.centerCoordinateDistance
        if distance < 2_000_000 {
            let point = map.convert(vertex.coordinate, toPointTo: self)
            return bounds.insetBy(dx: -20, dy: -20).contains(point) ? point : nil
        }
        return projection?.point(vertex.vector)
    }

    private func drawRoutes() {
        guard active, bounds.width > 0, bounds.height > 0 else { return }
        projection = GlobeProjection.Camera(center: map.camera.centerCoordinate, distance: map.camera.centerCoordinateDistance, size: bounds.size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for route in routes {
            let path = CGMutablePath()
            var previous: CGPoint?
            for coordinate in route.points {
                guard let point = projected(coordinate) else { previous = nil; continue }
                if let previous, hypot(point.x - previous.x, point.y - previous.y) < bounds.width * 0.4 {
                    path.addLine(to: point)
                } else { path.move(to: point) }
                previous = point
            }
            route.layer.path = path
            let completed = route.destination.isCompleted(at: now)
            route.layer.strokeColor = PlatformColor(hex: completed ? StintPalette.whiteHex : StintPalette.pitGrayHex).withAlphaComponent(completed ? 0.75 : 0.5).cgColor
            route.layer.lineDashPattern = completed ? nil : [4, 5]
            route.layer.lineWidth = 1.6
            route.layer.strokeStart = 0
            route.layer.strokeEnd = 1
        }
        highlightFlownRoute()
        var groups: [(point: CGPoint, races: [SeasonRace])] = []
        for venue in venues where map.camera.centerCoordinateDistance > 10_000 {
            let race = venue.race
            guard let point = projected(venue.vertex), bounds.contains(point) else { continue }
            if let index = groups.firstIndex(where: { hypot($0.point.x - point.x, $0.point.y - point.y) < 36 }) {
                groups[index].races.append(race)
            } else { groups.append((point, [race])) }
        }
        markerGroups = groups.map(\.races)
        for (index, button) in markerButtons.enumerated() {
            guard groups.indices.contains(index) else { button.isHidden = true; continue }
            let group = groups[index]
            let frame = CGRect(x: group.point.x - 14, y: group.point.y - 14, width: 28, height: 28)
            if button.frame != frame { button.frame = frame }
            if button.isHidden { button.isHidden = false }
            let complete = group.races.allSatisfy { $0.isCompleted(at: now) }
            let isSelected = group.races.contains { $0.id == selected }
            let signature = group.races.reduce(UInt64(0)) { $0 | (UInt64(1) << $1.id) }
                | (complete ? UInt64(1) << 63 : 0)
                | (isSelected ? UInt64(selected ?? 0) << 32 : 0)
            guard markerSignatures[index] != signature else { continue }
            markerSignatures[index] = signature
            let text = group.races.count == 1 ? String(group.races[0].round) : "\(group.races.count)×"
            let color = PlatformColor(hex: isSelected ? StintPalette.redHex : complete ? StintPalette.whiteHex : StintPalette.pitGrayHex)
            let ink = PlatformColor(hex: isSelected ? StintPalette.whiteHex : StintPalette.trackBlackHex)
            let label = group.races.count == 1 ? "Round \(group.races[0].round), \(group.races[0].name), \(group.races[0].cityName)" : "\(group.races.count) races. Zoom in."
            let identifier = group.races.count == 1 ? "venue-\(group.races[0].circuitID)" : "venue-cluster-\(group.races[0].id)"
            #if os(macOS)
            button.attributedTitle = NSAttributedString(string: text, attributes: [
                .foregroundColor: ink, .font: NSFont.systemFont(ofSize: 11, weight: .bold)
            ])
            button.layer?.backgroundColor = color.cgColor
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(identifier)
            #else
            button.setTitle(text, for: .normal)
            button.setTitleColor(ink, for: .normal)
            button.backgroundColor = color
            button.accessibilityLabel = label
            button.accessibilityIdentifier = identifier
            #endif

            let featured = group.races.first { $0.id == selected } ?? group.races[0]
            let city = group.races.count == 1 ? featured.cityName
                : isSelected ? "\(featured.cityName) +\(group.races.count - 1)" : "\(group.races.count) races"
            #if os(macOS)
            let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            #else
            let font = UIFont.systemFont(ofSize: 11, weight: .semibold)
            #endif
            let title = NSAttributedString(string: city, attributes: [.font: font, .foregroundColor: PlatformColor.white])
            cityLabels[index].string = title
            cityLabels[index].bounds.size = CGSize(width: ceil(title.size().width) + 10, height: ceil(title.size().height) + 2)
            cityLabels[index].backgroundColor = (isSelected ? PlatformColor(hex: StintPalette.redHex)
                : PlatformColor.black.withAlphaComponent(0.7)).cgColor
        }
        layoutCityLabels()
        CATransaction.commit()
    }

    /// Project the flown geographic prefix, leaving the remaining route visible underneath.
    private func highlightFlownRoute() {
        guard let itinerary = flownItinerary else { flownTrailLayer.path = nil; return }
        let position = planeFlight != nil ? (planePosition ?? itinerary.position(at: 0)) : nil
        let path = CGMutablePath()
        for (index, leg) in itinerary.legs.enumerated() {
            let fraction: Double
            if let position {
                fraction = index < position.legIndex ? 1 : index == position.legIndex ? position.legProgress : 0
            } else { fraction = 1 }
            guard fraction > 0 else { continue }
            var coordinates = leg.coordinates(through: fraction)
            if let position, index == position.legIndex {
                coordinates[coordinates.count - 1] = position.coordinate
            }
            var previous: CGPoint?
            for coordinate in coordinates {
                // Use the jet's projection, including offscreen points until layer clipping.
                guard let point = projectOnScreen(coordinate) else { previous = nil; continue }
                if let previous, hypot(point.x - previous.x, point.y - previous.y) < bounds.width * 0.4 {
                    path.addLine(to: point)
                } else { path.move(to: point) }
                previous = point
            }
        }
        flownTrailLayer.path = path
    }

    private func layoutCityLabels() {
        for label in cityLabels { label.isHidden = true }
        // Place the selected city first, then fit other labels around pins and labels.
        let indices = markerGroups.indices.sorted {
            let lhs = markerGroups[$0].contains { $0.id == selected }
            let rhs = markerGroups[$1].contains { $0.id == selected }
            return lhs != rhs ? lhs : $0 < $1
        }
        var occupied = markerButtons.filter { !$0.isHidden }.map { $0.frame.insetBy(dx: -2, dy: -2) }
        for index in indices {
            guard markerGroups[index].count == 1 || markerGroups[index].contains(where: { $0.id == selected }) else { continue }
            let pin = markerButtons[index].frame
            let label = cityLabels[index]
            let size = label.bounds.size
            let candidates = [
                CGRect(x: pin.maxX + 4, y: pin.midY - size.height / 2, width: size.width, height: size.height),
                CGRect(x: pin.minX - size.width - 4, y: pin.midY - size.height / 2, width: size.width, height: size.height),
                CGRect(x: pin.midX - size.width / 2, y: pin.maxY + 4, width: size.width, height: size.height),
                CGRect(x: pin.midX - size.width / 2, y: pin.minY - size.height - 4, width: size.width, height: size.height)
            ]
            guard let frame = candidates.first(where: { candidate in
                bounds.insetBy(dx: 4, dy: 4).contains(candidate) && !occupied.contains { $0.intersects(candidate) }
            }) else { continue }
            #if os(macOS)
            label.contentsScale = window?.backingScaleFactor ?? 2
            #else
            label.contentsScale = window?.screen.scale ?? traitCollection.displayScale
            #endif
            label.frame = frame
            label.isHidden = false
            occupied.append(frame.insetBy(dx: -3, dy: -3))
        }
    }
}

/// Coordinates and trigonometry are prepared once, outside the display loop.
private struct GlobeVertex {
    let coordinate: CLLocationCoordinate2D
    let vector: SIMD3<Double>
    init(_ coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        let phi = coordinate.latitude * .pi / 180
        let lambda = coordinate.longitude * .pi / 180
        vector = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
    }
}

/// Perspective projection of a spherical Earth, with back-side/horizon occlusion.
enum GlobeProjection {
    struct Camera {
        let front: SIMD3<Double>
        let east: SIMD3<Double>
        let north: SIMD3<Double>
        let radius = 6_371_000.0
        let cameraRadius: Double
        let focalLength: Double
        let size: CGSize
        init(center: CLLocationCoordinate2D, distance: Double, size: CGSize) {
            let phi = center.latitude * .pi / 180
            let lambda = center.longitude * .pi / 180
            front = SIMD3(cos(phi) * cos(lambda), cos(phi) * sin(lambda), sin(phi))
            east = SIMD3(-sin(lambda), cos(lambda), 0)
            north = SIMD3(-sin(phi) * cos(lambda), -sin(phi) * sin(lambda), cos(phi))
            cameraRadius = 6_371_000 + max(1, distance)
            focalLength = Double(size.height) / (2 * tan(.pi / 12))
            self.size = size
        }
        func point(_ vector: SIMD3<Double>) -> CGPoint? {
            let facing = simd_dot(vector, front)
            guard facing >= radius / cameraRadius else { return nil }
            let scale = focalLength * radius / (cameraRadius - radius * facing)
            return CGPoint(x: Double(size.width) / 2 + simd_dot(vector, east) * scale,
                           y: Double(size.height) / 2 - simd_dot(vector, north) * scale)
        }
    }
    static func point(_ coordinate: CLLocationCoordinate2D, center: CLLocationCoordinate2D,
                      distance: Double, size: CGSize) -> CGPoint? {
        Camera(center: center, distance: distance, size: size).point(GlobeVertex(coordinate).vector)
    }
}

private final class PassthroughSceneView: SCNView {
    #if os(macOS)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif
}

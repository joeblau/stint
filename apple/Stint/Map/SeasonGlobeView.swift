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
    let now: Date
    let onSelect: (SeasonRace) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    #if os(macOS)
    func makeNSView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateNSView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, reduceMotion: reduceMotion, onComplete: onFlightComplete) }
    #else
    func makeUIView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateUIView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, reduceMotion: reduceMotion, onComplete: onFlightComplete) }
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
    private(set) var planeFlight: (itinerary: GlobeItinerary, began: TimeInterval)?
    /// The last trip flown, kept highlighted on the route lines until the next selection.
    private var flownItinerary: GlobeItinerary?
    private var reduceMotion = false
    private static let flightCameraDistance = 5_000_000.0


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
        sceneView.isPlaying = true
        #if os(macOS)
        sceneView.wantsLayer = true
        sceneView.layer?.isOpaque = false
        sceneView.layer?.zPosition = 3
        #else
        sceneView.isOpaque = false
        sceneView.isUserInteractionEnabled = false
        sceneView.layer.zPosition = 3
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
            var coordinates = [a.point.coordinate, b.point.coordinate]
            let geodesic = MKGeodesicPolyline(coordinates: &coordinates, count: 2)
            var points = [CLLocationCoordinate2D](repeating: .init(), count: geodesic.pointCount)
            geodesic.getCoordinates(&points, range: NSRange(location: 0, length: points.count))
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineWidth = 1.6
            shape.lineCap = .round
            routesLayer.addSublayer(shape)
            routes.append((points.map(GlobeVertex.init), shape, b))
        }
        for index in Season2026.races.indices {
            #if os(macOS)
            let button = NSButton(title: "", target: self, action: #selector(selectVenue(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 14
            button.layer?.zPosition = 2
            #else
            let button = UIButton(type: .custom)
            button.addTarget(self, action: #selector(selectVenue(_:)), for: .touchUpInside)
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
        }
    }

    private func startDisplayClock() {
        guard active else { return }
        displayClock.start(in: self) { [weak self] _ in self?.displayFrame() }
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

    private func displayFrame() {
        if let flight = currentFlight {
            let progress = min(1, (ProcessInfo.processInfo.systemUptime - flight.began) / max(0.001, flight.request.duration))
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
            let elapsed = ProcessInfo.processInfo.systemUptime - plane.began
            if elapsed >= plane.itinerary.durationSeconds || plane.itinerary.isEmpty {
                landPlane(at: plane.itinerary.legs.last?.to)
            } else if let position = plane.itinerary.position(at: elapsed) {
                // The camera rides along; the map scrolls under the jet at one second per flight hour.
                map.setCamera(MKMapCamera(lookingAtCenter: position.coordinate, fromDistance: Self.flightCameraDistance,
                                          pitch: 0, heading: 0), animated: false)
                positionPlane(position)
                needsRedraw = true
            }
        }
        if needsRedraw { needsRedraw = false; drawRoutes() }
    }

    /// Flies the jet from one round to another along the calendar's route lines, leg by leg.
    /// Returns false when no flight starts (Reduce Motion, or the venues are too close).
    @discardableResult
    private func startPlaneFlight(from origin: SeasonRace, to destination: SeasonRace) -> Bool {
        guard !reduceMotion || ProcessInfo.processInfo.environment["STINT_FORCE_FLIGHT"] == "1" else { return false }
        var itinerary = GlobeItinerary.alongCalendar(from: origin, to: destination)
        if let active = planeFlight, let position = active.itinerary.position(at: ProcessInfo.processInfo.systemUptime - active.began) {
            // Redirect mid-air: the new trip departs from where the jet is now.
            itinerary = .direct(from: position.coordinate, to: destination.point.coordinate)
        }
        guard itinerary.distanceKm > 50 else { return false }
        planeFlight = (itinerary, ProcessInfo.processInfo.systemUptime)
        flownItinerary = itinerary
        if planeNode == nil {
            let node = PlaneModel.make()
            node.isHidden = true
            scene.rootNode.addChildNode(node)
            planeNode = node
        }
        planeNode?.removeAllActions()
        planeNode?.opacity = 1
        return true
    }

    private func landPlane(at destination: CLLocationCoordinate2D?) {
        planeFlight = nil
        if let node = planeNode {
            node.runAction(.fadeOut(duration: 0.6)) { node.isHidden = true }
        }
        if let destination {
            map.setCamera(MKMapCamera(lookingAtCenter: destination, fromDistance: 4_000_000, pitch: 0, heading: 0), animated: true)
        }
        needsRedraw = true
    }

    private func positionPlane(_ position: GlobeItinerary.Position) {
        guard let node = planeNode, bounds.width > 0, bounds.height > 0 else { return }
        projection = GlobeProjection.Camera(center: map.camera.centerCoordinate,
                                            distance: map.camera.centerCoordinateDistance, size: bounds.size)
        guard let point = projectOnScreen(position.coordinate), let ahead = projectOnScreen(position.ahead) else {
            node.isHidden = true
            return
        }
        let dx = ahead.x - point.x
        let dy = ahead.y - point.y
        guard hypot(dx, dy) > 0.0001 else { node.isHidden = true; return }
        let altitude = position.altitude
        let climb = Float(cos(position.legProgress * .pi) * 0.35) // nose up on climb, down on descent
        node.isHidden = false
        node.opacity = max(0, min(1, min(position.progress / 0.05, (1 - position.progress) / 0.08)))
        node.simdPosition = SIMD3(Float(point.x), Float(bounds.height - point.y), Float(60 + altitude * 26))
        // Nose along the track, top toward the camera, so the jet is seen from above.
        let back = -simd_normalize(SIMD3(Float(dx), -Float(dy), climb))
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 0, 1), back))
        let up = simd_cross(back, right)
        node.simdOrientation = simd_quatf(simd_float3x3(columns: (right, up, back)))
        // About 60 points long at cruise so the jet reads at globe scale.
        node.simdScale = SIMD3(repeating: Float(1.6 + altitude * 0.6))
        sceneCamera.simdPosition = SIMD3(Float(bounds.width / 2), Float(bounds.height / 2), 2_000)
        sceneCamera.camera?.orthographicScale = Double(bounds.height / 2)
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

    func update(selected: Int?, overview: UUID, now: Date, active: Bool, flight: MapFlight?, reduceMotion: Bool, onComplete: @escaping () -> Void) {
        setActive(active)
        onFlightComplete = onComplete
        self.reduceMotion = reduceMotion
        if !Calendar.current.isDate(self.now, inSameDayAs: now) { needsRedraw = true }
        self.now = now
        if let flight, lastFlightID != flight.id {
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
            map.setCamera(MKMapCamera(lookingAtCenter: .init(latitude: 20, longitude: 15),
                                     fromDistance: 40_000_000, pitch: 0, heading: 0), animated: false)
        }
        if currentFlight == nil, self.selected != selected {
            let previous = self.selected
            self.selected = selected
            needsRedraw = true
            if let race = Season2026.races.first(where: { $0.id == selected }) {
                var flying = false
                if let previous, let origin = Season2026.races.first(where: { $0.id == previous }) {
                    flying = startPlaneFlight(from: origin, to: race)
                } else {
                    flownItinerary = nil
                }
                if !flying {
                    map.setCamera(MKMapCamera(lookingAtCenter: race.point.coordinate,
                                             fromDistance: 4_000_000, pitch: 0, heading: 0), animated: true)
                }
            } else {
                planeFlight = nil
                flownItinerary = nil
                planeNode?.isHidden = true
            }
        }
    }

    @objc private func selectVenue(_ sender: VenueButton) {
        guard currentFlight == nil, markerGroups.indices.contains(sender.tag) else { return }
        let races = markerGroups[sender.tag]
        if races.count == 1 {
            let race = races[0]
            // A pin is a direct request to inspect the circuit, including a second
            // click on the current selection after panning or zooming away.
            // Set this first so SwiftUI's selection update cannot zoom back out.
            selected = race.id
            onSelect(race)
            map.setCamera(MKMapCamera(lookingAtCenter: race.point.coordinate,
                                     fromDistance: 6_000, pitch: 0, heading: 0), animated: true)
            needsRedraw = true
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

    /// Paints the jet's legs red along the calendar route: legs already flown in full, the
    /// current leg up to the jet, and the rest untouched.
    private func highlightFlownRoute() {
        guard let itinerary = flownItinerary, itinerary.rounds.count >= 2 else { return }
        let elapsed = planeFlight.map { ProcessInfo.processInfo.systemUptime - $0.began } ?? .infinity
        let position = planeFlight?.itinerary.position(at: elapsed)
        for (legIndex, pair) in zip(itinerary.rounds, itinerary.rounds.dropFirst()).enumerated() {
            let (a, b) = pair
            // Route lines are stored in calendar order: the line at index i joins rounds i+1 and i+2.
            let routeIndex = min(a, b) - 1
            guard routes.indices.contains(routeIndex) else { continue }
            let fraction: CGFloat
            if let position {
                fraction = legIndex < position.legIndex ? 1 : legIndex == position.legIndex ? CGFloat(position.legProgress) : 0
            } else {
                fraction = 1
            }
            guard fraction > 0 else { continue }
            let layer = routes[routeIndex].layer
            layer.strokeColor = PlatformColor(hex: StintPalette.redHex).withAlphaComponent(0.95).cgColor
            layer.lineDashPattern = nil
            layer.lineWidth = 2.4
            if b > a { layer.strokeStart = 0; layer.strokeEnd = fraction }
            else { layer.strokeStart = 1 - fraction; layer.strokeEnd = 1 }
        }
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

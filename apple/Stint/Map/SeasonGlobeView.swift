import SwiftUI
import MapKit
import simd

struct SeasonGlobeView: PlatformRepresentable {
    let active: Bool
    let flight: MapFlight?
    let onFlightComplete: () -> Void
    let selected: Int?
    let overviewRequest: UUID
    let now: Date
    let onSelect: (SeasonRace) -> Void

    #if os(macOS)
    func makeNSView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateNSView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, onComplete: onFlightComplete) }
    #else
    func makeUIView(context: Context) -> SeasonGlobeSurface { SeasonGlobeSurface(onSelect: onSelect) }
    func updateUIView(_ view: SeasonGlobeSurface, context: Context) { view.update(selected: selected, overview: overviewRequest, now: now, active: active, flight: flight, onComplete: onFlightComplete) }
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


    init(onSelect: @escaping (SeasonRace) -> Void) {
        self.onSelect = onSelect
        super.init(frame: .zero)
        isHidden = true
        #if os(macOS)
        wantsLayer = true
        #endif
        map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        map.showsCompass = false
        map.showsScale = false
        map.isPitchEnabled = false
        map.isZoomEnabled = true
        map.isScrollEnabled = true
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll
        map.delegate = self
        addSubview(map)
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
        if needsRedraw { needsRedraw = false; drawRoutes() }
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
        if globe { map.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic) }
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
        needsRedraw = true
    }

    func update(selected: Int?, overview: UUID, now: Date, active: Bool, flight: MapFlight?, onComplete: @escaping () -> Void) {
        setActive(active)
        onFlightComplete = onComplete
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
            self.selected = selected
            needsRedraw = true
            if let race = Season2026.races.first(where: { $0.id == selected }) {
                map.setCamera(MKMapCamera(lookingAtCenter: race.point.coordinate,
                                         fromDistance: 4_000_000, pitch: 0, heading: 0), animated: true)
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
        }
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
            let signature = group.races.reduce(UInt64(0)) { $0 | (UInt64(1) << $1.id) } | (complete ? UInt64(1) << 63 : 0) | (isSelected ? UInt64(1) << 62 : 0)
            guard markerSignatures[index] != signature else { continue }
            markerSignatures[index] = signature
            let text = group.races.count == 1 ? String(group.races[0].round) : "\(group.races.count)×"
            let color = PlatformColor(hex: isSelected ? StintPalette.redHex : complete ? StintPalette.whiteHex : StintPalette.pitGrayHex)
            let ink = PlatformColor(hex: isSelected ? StintPalette.whiteHex : StintPalette.trackBlackHex)
            let label = group.races.count == 1 ? "Round \(group.races[0].round), \(group.races[0].name)" : "\(group.races.count) races. Zoom in."
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
        }
        CATransaction.commit()
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

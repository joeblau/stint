import MapKit
import Network

/// Warms MapKit's shared tile cache for every circuit and the globe so camera
/// flights and first visits never cross unloaded regions. MapKit offers no
/// public prefetch API, so this visits each region on a full-size, effectively
/// invisible map and lets the normal loader populate the cache. Tiles differ
/// per map configuration, so circuit altitudes are warmed with the race map's
/// standard style and high altitudes with the globe's hybrid style.
@MainActor
final class MapTileWarmer: NSObject, MKMapViewDelegate {
    let map = MKMapView()
    private struct Step {
        let distance: CLLocationDistance
        let center: CLLocationCoordinate2D
        let globeStyle: Bool
    }
    private var steps: [Step] = []
    private var globeStyle = false
    private var advanceTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private static let warmedKey = "map-tile-cache-warmed-v2"

    override init() {
        super.init()
        map.delegate = self
        map.isPitchEnabled = false
        map.isRotateEnabled = false
        map.isZoomEnabled = false
        map.isScrollEnabled = false
        map.pointOfInterestFilter = .excludingAll
        #if os(macOS)
        map.alphaValue = 0.01
        #else
        map.alpha = 0.01
        map.isUserInteractionEnabled = false
        #endif
    }

    func start() {
        guard !UserDefaults.standard.bool(forKey: Self.warmedKey),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            monitor.cancel()
            // Defer to a metered or data-saver connection rather than marking the cache warm.
            let usable = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                self?.pathMonitor = nil
                guard usable else { return }
                self?.buildSteps()
                self?.run()
            }
        }
        monitor.start(queue: .main)
    }

    private func buildSteps() {
        let globeCenter = GeoPoint(latitude: 20, longitude: 15)
        for race in Season2026.races {
            let track = race.point
            for distance in [2_500.0, 12_000, 60_000, 250_000] {
                steps.append(Step(distance: distance, center: track.coordinate, globeStyle: false))
            }
            for (distance, fraction) in [(900_000.0, 0.25), (3_000_000.0, 0.5), (10_000_000.0, 0.75)] {
                steps.append(Step(distance: distance,
                                  center: track.interpolated(to: globeCenter, fraction: fraction).coordinate,
                                  globeStyle: distance > 2_000_000))
            }
        }
        for longitude in [-120.0, 0.0, 120.0] {
            steps.append(Step(distance: 40_000_000, center: CLLocationCoordinate2D(latitude: 20, longitude: longitude), globeStyle: true))
        }
    }

    private func run() {
        guard let step = steps.first else {
            UserDefaults.standard.set(true, forKey: Self.warmedKey)
            map.removeFromSuperview()
            return
        }
        steps.removeFirst()
        if globeStyle != step.globeStyle {
            globeStyle = step.globeStyle
            map.preferredConfiguration = step.globeStyle
                ? MKHybridMapConfiguration(elevationStyle: .realistic)
                : MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        }
        map.setCamera(MKMapCamera(lookingAtCenter: step.center, fromDistance: step.distance, pitch: 0, heading: 0), animated: false)
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.run()
        }
    }

    nonisolated func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
        guard fullyRendered else { return }
        Task { @MainActor in
            self.advanceTask?.cancel()
            self.run()
        }
    }
}

import SwiftUI
import Observation
import MapKit

@MainActor @Observable
final class RaceSession {
    @ObservationIgnored var displayedCamera: MKMapCamera?
    let overlays = OverlayVisibility()
    var replay: RaceReplay?
    var revision = UUID()
    var sourceName = "SIMULATED"
    var demoCircuit: DemoCircuit? = .monaco
    var time: Double = 0
    var isPlaying = true
    var playbackRate: Double = 1
    var selectedDriverID: String?
    var followsDriver = false
    var satellite = false
    var lighting = RaceLighting.raceTime
    @ObservationIgnored private var lightingCache: (revision: UUID, circuit: String?, minute: Int, day: Bool)?
    @ObservationIgnored private var timingCache: (revision: UUID, timing: RaceTiming)?
    var followsHeading = true
    var tilted = true
    var showLabels = true
    var carScale: Double = 1
    var cameraRequest = UUID()
    var error: String?
    var importing = false

    var lightingRace: SeasonRace? { Season2026.races.first { $0.circuitID == demoCircuit?.id } }
    var lightingPoint: GeoPoint { replay?.circuit.first ?? GeoPoint(latitude: 0, longitude: 0) }
    var lightingTimeZone: TimeZone {
        if let race = lightingRace { return race.calendar.timeZone }
        return TimeZone(secondsFromGMT: Int((lightingPoint.longitude / 15).rounded()) * 3600) ?? .gmt
    }
    var lightingDate: Date {
        let start = lightingRace?.lightingStartDate ?? {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = lightingTimeZone
            return calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 15))!
        }()
        return start.addingTimeInterval(floor(time / 60) * 60)
    }
    var lightingIsDay: Bool {
        if lighting != .raceTime { return lighting == .day }
        let minute = Int(time / 60)
        if let cache = lightingCache, cache.revision == revision, cache.circuit == demoCircuit?.id, cache.minute == minute {
            return cache.day
        }
        let day = lighting.isDay(at: lightingDate, point: lightingPoint)
        lightingCache = (revision, demoCircuit?.id, minute, day)
        return day
    }
    var lightingTimeLabel: String {
        let formatter = DateFormatter()
        formatter.timeZone = lightingTimeZone
        formatter.dateFormat = "HH:mm"
        let prefix = lightingRace?.raceStartHour == nil ? "Demo time" : "Race time"
        return "\(prefix) · \(formatter.string(from: lightingDate)) local"
    }

    var duration: Double { replay?.duration ?? 1 }
    /// Lap, sector, and gap timing derived once per replay.
    var timing: RaceTiming? {
        guard let replay else { return nil }
        if let cache = timingCache, cache.revision == revision { return cache.timing }
        let timing = RaceTiming(replay: replay)
        timingCache = (revision, timing)
        return timing
    }
    var timingRows: [String: RaceTiming.Row] { timing?.rows(at: time, order: standings) ?? [:] }
    var positions: [CarPosition] { replay?.recordings.map { $0.position(at: time) } ?? [] }
    var selectedPosition: CarPosition? { positions.first { $0.id == selectedDriverID } }
    var standings: [CarPosition] {
        positions.enumerated().sorted {
            let a = $0.element.racePosition ?? Int.max
            let b = $1.element.racePosition ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
    }

    init() { loadDemo(.monaco) }

    func loadDemo(_ circuit: DemoCircuit) {
        do {
            install(try circuit.load(), source: "SIMULATED")
            demoCircuit = circuit
        } catch { self.error = error.localizedDescription }
    }

    func install(_ replay: RaceReplay, source: String) {
        self.replay = replay
        lighting = .raceTime
        sourceName = source
        demoCircuit = nil
        time = 0
        if !replay.recordings.contains(where: { $0.driver.id == selectedDriverID }) {
            selectedDriverID = replay.recordings.first?.driver.id
        }
        isPlaying = true
        revision = UUID()
        cameraRequest = UUID()
    }

    func importReplay(from url: URL) async {
        guard !importing else { return }
        importing = true
        defer { importing = false }
        do {
            let replay = try await Task.detached(priority: .userInitiated) {
                let granted = url.startAccessingSecurityScopedResource()
                defer { if granted { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 50_000_000 else { throw ReplayError.invalid("Choose a replay smaller than 50 MB.") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= 50_000_000 else { throw ReplayError.invalid("Choose a replay smaller than 50 MB.") }
                return try JSONDecoder().decode(RaceReplay.self, from: data).validated()
            }.value
            install(replay, source: "IMPORTED REPLAY")
        } catch { self.error = "Couldn’t open replay. \(error.localizedDescription)" }
    }

    func advance(by elapsed: Double) {
        guard isPlaying, replay != nil else { return }
        // Ignore suspension/background gaps instead of jumping forward several laps.
        time = min(duration, time + min(elapsed, 0.25) * playbackRate)
        if time >= duration { isPlaying = false }
    }

    func togglePlayback() {
        if time >= duration { time = 0 }
        isPlaying.toggle()
    }

    func overview() {
        followsDriver = false
        cameraRequest = UUID()
    }

    func toggleFollow() {
        followsDriver.toggle()
        if followsDriver {
            tilted = true
            followsHeading = true
        }
    }
}

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
    /// UI snapshot clock. Native rendering advances independently at display cadence.
    var time: Double = 0 {
        didSet { renderTime = time }
    }
    @ObservationIgnored private(set) var renderTime: Double = 0
    @ObservationIgnored private var hudElapsed: Double = 0
    @ObservationIgnored private var positionsCache: (revision: UUID, time: Double, positions: [CarPosition])?
    @ObservationIgnored private var standingsCache: (revision: UUID, time: Double, positions: [CarPosition])?
    @ObservationIgnored private var rowsCache: (revision: UUID, time: Double, rows: [String: RaceTiming.Row])?
    var isPlaying = true
    var playbackRate: Double = 1
    var selectedDriverID: String?
    var followsDriver = false
    var satellite = false
    var lighting = RaceLighting.raceTime
    @ObservationIgnored private var lightingCache: (revision: UUID, circuit: String?, minute: Int, day: Bool)?
    private(set) var timing: RaceTiming?
    @ObservationIgnored private var timingTask: Task<Void, Never>?
    var followsHeading = true
    var tilted = true
    var showLabels = true
    var carScale: Double = 1
    var cameraRequest = UUID()
    var error: String?

    var lightingRace: SeasonRace? { Season2026.races.first { $0.circuitID == demoCircuit?.id } }
    var lightingPoint: GeoPoint { replay?.circuit.first ?? GeoPoint(latitude: 0, longitude: 0) }
    var lightingTimeZone: TimeZone {
        if let race = lightingRace { return race.calendar.timeZone }
        return TimeZone(secondsFromGMT: Int((lightingPoint.longitude / 15).rounded()) * 3600) ?? .gmt
    }
    var lightingDate: Date {
        let start = replay?.startDate ?? lightingRace?.lightingStartDate ?? {
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
        let prefix = replay?.startDate == nil && lightingRace?.raceStartHour == nil ? "Demo time" : "Race time"
        return "\(prefix) · \(formatter.string(from: lightingDate)) local"
    }

    var duration: Double { replay?.duration ?? 1 }
    var timingRows: [String: RaceTiming.Row] {
        let timing = timing // Observe completion even when a row snapshot is cached.
        if let cache = rowsCache, cache.revision == revision, cache.time == time { return cache.rows }
        let rows = timing?.rows(at: time, order: standings) ?? [:]
        rowsCache = (revision, time, rows)
        return rows
    }
    var positions: [CarPosition] {
        if let cache = positionsCache, cache.revision == revision, cache.time == time { return cache.positions }
        let positions = replay?.recordings.map { $0.position(at: time) } ?? []
        positionsCache = (revision, time, positions)
        return positions
    }
    var selectedPosition: CarPosition? { positions.first { $0.id == selectedDriverID } }
    var standings: [CarPosition] {
        if let cache = standingsCache, cache.revision == revision, cache.time == time { return cache.positions }
        let result = positions.enumerated().sorted {
            let a = $0.element.racePosition ?? Int.max
            let b = $1.element.racePosition ?? Int.max
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        standingsCache = (revision, time, result)
        return result
    }

    init() { loadDemo(.monaco) }
    deinit { timingTask?.cancel() }

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
        hudElapsed = 0
        prepareTiming(replay: replay)
    }

    private func prepareTiming(replay: RaceReplay) {
        timingTask?.cancel()
        timing = nil
        rowsCache = nil
        let expectedRevision = revision
        timingTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { RaceTiming(replay: replay) }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let self, self.revision == expectedRevision else { return }
            self.rowsCache = nil
            self.timing = result
        }
    }

    func advance(by elapsed: Double) {
        guard isPlaying, replay != nil else { return }
        // Ignore suspension/background gaps instead of jumping forward several laps.
        time = min(duration, time + min(elapsed, 0.25) * playbackRate)
        if time >= duration { isPlaying = false }
    }

    /// Publish telemetry at 10 Hz, while retaining full precision for cars and camera.
    /// Explicit seeks still update both clocks immediately through `time`.
    func advanceFrame(by elapsed: Double) {
        guard isPlaying, replay != nil else { return }
        let delta = min(max(0, elapsed), 0.25)
        renderTime = min(duration, renderTime + delta * playbackRate)
        hudElapsed += delta
        if hudElapsed >= 0.1 || renderTime >= duration {
            hudElapsed = hudElapsed.truncatingRemainder(dividingBy: 0.1)
            time = renderTime
        }
        if renderTime >= duration { isPlaying = false }
    }

    func togglePlayback() {
        if time >= duration { time = 0 }
        if isPlaying { time = renderTime }
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

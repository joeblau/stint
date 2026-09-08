import Foundation
import Observation

struct SavedRaceReplay: Codable {
    let version: Int
    let circuitID: String
    let year: Int
    let sessionKey: Int
    let downloadedAt: Date
    let replay: RaceReplay
}

struct ReplayStorage {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stint/Replays", isDirectory: true)
    }
    func url(for circuitID: String) -> URL { directory.appendingPathComponent("2026-\(circuitID).json") }
    func savedCircuitIDs() -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let names = Set(files.map(\.lastPathComponent))
        return Set(Season2026.races.filter { names.contains(url(for: $0.circuitID).lastPathComponent) }.map(\.circuitID))
    }
    func load(_ race: SeasonRace) throws -> SavedRaceReplay {
        let data = try Data(contentsOf: url(for: race.circuitID), options: .mappedIfSafe)
        let saved = try JSONDecoder().decode(SavedRaceReplay.self, from: data)
        guard saved.version == 1, saved.year == 2026, saved.circuitID == race.circuitID, saved.sessionKey > 0 else {
            throw ReplayError.invalid("This saved replay doesn’t match the selected race. Download it again.")
        }
        _ = try saved.replay.validated()
        return saved
    }
    func save(_ replay: SavedRaceReplay) throws {
        _ = try replay.replay.validated()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(replay)
        try Task.checkCancellation()
        try data.write(to: url(for: replay.circuitID), options: .atomic)
    }
}

actor RaceReplayDownloader {
    let client: OpenF1Client
    init(client: OpenF1Client = OpenF1Client()) { self.client = client }

    func download(_ race: SeasonRace, now: Date = Date(),
                  progress: @Sendable (Double, String) async -> Void) async throws -> SavedRaceReplay {
        await progress(0, "Finding race…")
        let sessions: [OpenF1.Session] = try await client.get("sessions", query: ["year": "2026", "session_name": "Race"])
        let matches = sessions.filter { $0.matches(race) }
        guard matches.count == 1, let session = matches.first else {
            throw ReplayError.invalid("OpenF1 has no race replay for \(race.name) on \(race.dateLabel) 2026 yet.")
        }
        guard now >= session.dateEnd.addingTimeInterval(30 * 60) else {
            throw ReplayError.invalid("This replay will be available after the race. Try again at least 30 minutes after the session ends.")
        }
        let query = ["session_key": String(session.sessionKey)]
        await progress(0.02, "Downloading race timing…")
        let drivers: [OpenF1.DriverInfo] = try await client.get("drivers", query: query)
        let laps: [OpenF1.Lap] = try await client.get("laps", query: query)
        let positions: [OpenF1.Position] = try await client.get("position", query: query)
        let intervals: [OpenF1.Interval] = try await client.get("intervals", query: query)
        let stints: [OpenF1.Stint] = try await client.get("stints", query: query)
        // Drivers with no laps never started; do not fabricate recordings for them.
        let starters = Set(laps.map(\.driverNumber))
        let field = Dictionary(grouping: drivers.filter { starters.contains($0.driverNumber) }, by: \.driverNumber)
            .compactMap { $0.value.first }.sorted { $0.driverNumber < $1.driverNumber }
        guard !field.isEmpty, field.count <= 24, let start = laps.filter({ $0.lapNumber == 1 }).compactMap(\.dateStart).min(),
              start < session.dateEnd else { throw ReplayError.invalid("OpenF1 has no complete race timing for this weekend yet.") }
        // Session metadata contains the scheduled finish; red flags can extend the race.
        let recordedFinish = laps.compactMap { lap -> Date? in
            guard let start = lap.dateStart, let duration = lap.lapDuration,
                  duration.isFinite, duration > 0 else { return nil }
            return start.addingTimeInterval(duration)
        }.max()
        let end = max(session.dateEnd, recordedFinish ?? session.dateEnd)
        let circuit = try race.circuit.loadCircuit()
        var transform: OpenF1MapTransform?
        var recordings: [DriverRecording] = []
        var skipped: [String] = []
        // Try a driver with a full lap first; retirees may not have completed one.
        let orderedField = field.sorted { a, b in
            laps.filter { $0.driverNumber == a.driverNumber }.count > laps.filter { $0.driverNumber == b.driverNumber }.count
        }
        for (index, info) in orderedField.enumerated() {
            try Task.checkCancellation()
            let fraction = 0.1 + 0.85 * Double(index) / Double(field.count)
            await progress(fraction, "Downloading \(info.driver.name) · \(index + 1)/\(field.count)")
            var driverQuery = query
            driverQuery["driver_number"] = String(info.driverNumber)
            let locations: [OpenF1.Location] = try await client.get("location", query: driverQuery)
            let driverLaps = laps.filter { $0.driverNumber == info.driverNumber }
            // A driver whose location feed is missing or incomplete is left out of the replay
            // rather than failing the whole download. Network errors still abort.
            do {
                try OpenF1ReplayBuilder.validateCoverage(locations: locations, laps: driverLaps, driver: info.driver.name)
            } catch is OpenF1DownloadError {
                await client.invalidate("location", query: driverQuery)
                skipped.append(info.driver.name)
                continue
            }
            if transform == nil {
                do {
                    transform = try OpenF1ReplayBuilder.transform(locations: locations.sorted { $0.date < $1.date },
                                                                  laps: driverLaps, circuit: circuit)
                } catch {
                    // This driver has no lap that aligns with the map; a later one may.
                    skipped.append(info.driver.name)
                    await client.invalidate("location", query: driverQuery)
                    continue
                }
            }
            let telemetry: [OpenF1.CarData] = try await client.get("car_data", query: driverQuery)
            do {
                let recording = try OpenF1ReplayBuilder.recording(driver: info.driver, locations: locations, telemetry: telemetry,
                    positions: positions.filter { $0.driverNumber == info.driverNumber },
                    intervals: intervals.filter { $0.driverNumber == info.driverNumber },
                    stints: stints.filter { $0.driverNumber == info.driverNumber }, transform: transform!, start: start, end: end)
                recordings.append(recording)
            } catch is ReplayError {
                skipped.append(info.driver.name)
            }
        }
        guard !recordings.isEmpty else {
            throw OpenF1DownloadError.noUsableLocations
        }
        if !skipped.isEmpty {
            await progress(0.96, "Skipped \(skipped.count) driver\(skipped.count == 1 ? "" : "s") without location data: \(skipped.joined(separator: ", "))")
        }
        await progress(0.97, "Saving replay…")
        let replay = try RaceReplay(version: 1, title: "\(race.name) 2026", circuit: circuit,
                                    recordings: recordings.sorted { ($0.gridPosition ?? 99) < ($1.gridPosition ?? 99) },
                                    totalLaps: laps.map(\.lapNumber).max(), startDate: start).validated()
        return SavedRaceReplay(version: 1, circuitID: race.circuitID, year: 2026, sessionKey: session.sessionKey,
                               downloadedAt: now, replay: replay)
    }
}

@MainActor @Observable
final class ReplayLibrary {
    private(set) var savedCircuitIDs: Set<String> = []
    private(set) var downloadingCircuitID: String?
    private(set) var progress = 0.0
    private(set) var progressLabel = ""
    var error: String?
    @ObservationIgnored private let storage: ReplayStorage
    @ObservationIgnored private let downloader: RaceReplayDownloader
    @ObservationIgnored private var downloadTask: Task<Void, Never>?

    init(storage: ReplayStorage = ReplayStorage(), downloader: RaceReplayDownloader = RaceReplayDownloader()) {
        self.storage = storage
        self.downloader = downloader
        savedCircuitIDs = storage.savedCircuitIDs()
    }
    deinit { downloadTask?.cancel() }

    func isSaved(_ race: SeasonRace) -> Bool { savedCircuitIDs.contains(race.circuitID) }
    func cancelDownload() { downloadTask?.cancel() }

    func download(_ race: SeasonRace) {
        guard downloadingCircuitID == nil, !isSaved(race) else { return }
        error = nil
        downloadingCircuitID = race.circuitID
        progress = 0
        progressLabel = "Finding race…"
        let storage = storage
        let downloader = downloader
        downloadTask = Task { [weak self] in
            defer { self?.downloadingCircuitID = nil; self?.downloadTask = nil }
            do {
                let saved = try await downloader.download(race) { [weak self] fraction, label in
                    await self?.updateProgress(fraction, label: label)
                }
                let writer = Task.detached(priority: .utility) { try storage.save(saved) }
                try await withTaskCancellationHandler { try await writer.value } onCancel: { writer.cancel() }
                self?.savedCircuitIDs.insert(race.circuitID)
            } catch is CancellationError {
                // Cancellation never marks a partial download as saved.
            } catch let failure as URLError where failure.code == .cancelled {
            } catch { self?.error = "Couldn’t download \(race.name). \(error.localizedDescription)" }
        }
    }

    func load(_ race: SeasonRace) async throws -> RaceReplay {
        let storage = storage
        do {
            return try await Task.detached(priority: .userInitiated) { try storage.load(race).replay }.value
        } catch {
            savedCircuitIDs.remove(race.circuitID)
            throw ReplayError.invalid("Couldn’t open the saved replay. Download \(race.name) again. \(error.localizedDescription)")
        }
    }

    private func updateProgress(_ fraction: Double, label: String) {
        progress = fraction
        progressLabel = label
    }
}

import XCTest
@testable import Stint

final class OpenF1DownloadTests: XCTestCase {
    private func client(failingEndpoint: String? = nil, sessions: String? = nil) throws -> OpenF1Client {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "openf1-monaco-lap", withExtension: "json"))
        let bodies: [String: Data] = [
            "sessions": Data((sessions ?? """
            [{"session_key":11299,"session_name":"Race","date_start":"2026-06-07T13:00:00Z","date_end":"2026-06-07T15:00:00Z","circuit_short_name":"Monte Carlo","year":2026,"is_cancelled":false}]
            """).utf8),
            "drivers": Data("""
            [{"driver_number":16,"full_name":"Charles Leclerc","name_acronym":"LEC","team_colour":"E80020","team_name":"Ferrari"}]
            """.utf8),
            "laps": Data("""
            [{"driver_number":16,"lap_number":1,"date_start":"2026-06-07T13:04:37.816Z","lap_duration":78.553,"is_pit_out_lap":false},
             {"driver_number":16,"lap_number":2,"date_start":"2026-06-07T13:04:37.816Z","lap_duration":78.553,"is_pit_out_lap":false}]
            """.utf8),
            "position": Data("""
            [{"driver_number":16,"date":"2026-06-07T13:00:00Z","position":1}]
            """.utf8),
            "intervals": Data("[]".utf8), "stints": Data("[]".utf8),
            "location": try Data(contentsOf: fixture),
            "car_data": Data("""
            [{"date":"2026-06-07T13:04:37.900Z","speed":200,"throttle":100,"brake":0,"drs":8,"n_gear":6,"rpm":11500}]
            """.utf8)
        ]
        OpenF1Stub.configure(bodies: bodies, failingEndpoint: failingEndpoint)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenF1Stub.self]
        return OpenF1Client(session: URLSession(configuration: configuration), requestSpacing: 0)
    }

    @MainActor func testDownloadPersistsReplayAndFreshLibraryReopensWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReplayStorage(directory: directory)
        let library = ReplayLibrary(storage: storage, downloader: RaceReplayDownloader(client: try client()))
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        library.download(race)
        try await finish(library)
        XCTAssertNil(library.error)
        XCTAssertTrue(library.isSaved(race))
        let requests = OpenF1Stub.requests
        XCTAssertTrue(requests.allSatisfy { $0.host == "api.openf1.org" })
        for request in requests where request.lastPathComponent != "sessions" {
            let query = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertTrue(query?.contains(URLQueryItem(name: "session_key", value: "11299")) == true)
        }
        OpenF1Stub.configure(bodies: [:], failingEndpoint: nil)
        let reopened = ReplayLibrary(storage: storage)
        let replay = try await reopened.load(race)
        XCTAssertEqual(replay.recordings.first?.driver.id, "LEC")
        XCTAssertGreaterThan(replay.duration, 70)
        XCTAssertTrue(OpenF1Stub.requests.isEmpty)
    }

    @MainActor func testDriverWithoutLocationDataIsSkippedInsteadOfFailingTheDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReplayStorage(directory: directory)
        let openF1 = try client()
        OpenF1Stub.add(bodies: [
            "drivers": Data("""
            [{"driver_number":16,"full_name":"Charles Leclerc","name_acronym":"LEC","team_colour":"E80020","team_name":"Ferrari"},
             {"driver_number":5,"full_name":"Gabriel Bortoleto","name_acronym":"BOR","team_colour":"00E701","team_name":"Kick Sauber"}]
            """.utf8),
            "laps": Data("""
            [{"driver_number":16,"lap_number":1,"date_start":"2026-06-07T13:04:37.816Z","lap_duration":78.553,"is_pit_out_lap":false},
             {"driver_number":16,"lap_number":2,"date_start":"2026-06-07T13:04:37.816Z","lap_duration":78.553,"is_pit_out_lap":false},
             {"driver_number":5,"lap_number":1,"date_start":"2026-06-07T13:04:37.816Z","lap_duration":80.1,"is_pit_out_lap":false}]
            """.utf8),
            "location?driver_number=5": Data("[]".utf8),
        ])
        let library = ReplayLibrary(storage: storage, downloader: RaceReplayDownloader(client: openF1))
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        library.download(race)
        try await finish(library)
        XCTAssertNil(library.error)
        XCTAssertTrue(library.isSaved(race))
        let replay = try await library.load(race)
        XCTAssertEqual(replay.recordings.map(\.driver.id), ["LEC"])
    }

    @MainActor func testFailedDownloadLeavesNoSavedFileAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReplayStorage(directory: directory)
        let library = ReplayLibrary(storage: storage, downloader: RaceReplayDownloader(client: try client(failingEndpoint: "car_data")))
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        library.download(race)
        try await finish(library)
        XCTAssertNotNil(library.error)
        XCTAssertFalse(library.isSaved(race))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.url(for: race.circuitID).path))
        _ = try client()
        library.download(race)
        try await finish(library)
        XCTAssertNil(library.error)
        XCTAssertTrue(library.isSaved(race))
    }

    func testUnavailableRaceDoesNotFetchAnotherSession() async throws {
        let downloader = RaceReplayDownloader(client: try client(sessions: "[]"))
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        do {
            _ = try await downloader.download(race) { _, _ in }
            XCTFail("Missing race must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no race replay")) }
        XCTAssertEqual(OpenF1Stub.requests.count, 1)
    }

    func testLiveSessionCannotBeDownloadedAsFreeHistory() async throws {
        let downloader = RaceReplayDownloader(client: try client())
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        do {
            _ = try await downloader.download(race, now: race.lightingStartDate) { _, _ in }
            XCTFail("Live session must wait for historical availability")
        } catch { XCTAssertTrue(error.localizedDescription.contains("30 minutes")) }
        XCTAssertEqual(OpenF1Stub.requests.count, 1)
    }

    @MainActor func testCancelledDownloadDoesNotSave() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = ReplayLibrary(storage: ReplayStorage(directory: directory), downloader: RaceReplayDownloader(client: try client()))
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        library.download(race)
        library.cancelDownload()
        try await finish(library)
        XCTAssertNil(library.error)
        XCTAssertFalse(library.isSaved(race))
    }

    func testLiveOpenF1DownloadWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["STINT_OPENF1_LIVE"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_STINT_OPENF1_LIVE=1 to validate a complete download against OpenF1.")
        }
        let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == "monaco" })
        let saved: SavedRaceReplay
        do { saved = try await RaceReplayDownloader().download(race) { _, _ in } }
        catch let error as OpenF1DownloadError {
            throw XCTSkip("Live provider has incomplete race coverage: \(error.localizedDescription)")
        }
        XCTAssertEqual(saved.sessionKey, 11299)
        XCTAssertGreaterThan(saved.replay.recordings.count, 15)
        XCTAssertGreaterThan(saved.replay.duration, 3600)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ReplayStorage(directory: directory)
        try storage.save(saved)
        XCTAssertEqual(try storage.load(race).replay.recordings.count, saved.replay.recordings.count)
    }

    @MainActor private func finish(_ library: ReplayLibrary) async throws {
        let deadline = Date().addingTimeInterval(15)
        while library.downloadingCircuitID != nil && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(library.downloadingCircuitID)
    }
}

private final class OpenF1Stub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var bodies: [String: Data] = [:]
    private static var failingEndpoint: String?
    private static var recordedRequests: [URL] = []
    static var requests: [URL] { lock.withLock { recordedRequests } }
    static func add(bodies extra: [String: Data]) {
        lock.withLock { bodies.merge(extra) { _, new in new } }
    }
    static func configure(bodies: [String: Data], failingEndpoint: String?) {
        lock.withLock {
            self.bodies = bodies
            self.failingEndpoint = failingEndpoint
            recordedRequests = []
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let (body, status) = Self.lock.withLock {
            Self.recordedRequests.append(url)
            // Per-driver bodies use "endpoint?driver_number=N"; plain endpoint names are the fallback.
            let driver = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "driver_number" }?.value
            let body = driver.flatMap { Self.bodies["\(url.lastPathComponent)?driver_number=\($0)"] } ?? Self.bodies[url.lastPathComponent]
            return (body ?? Data(), Self.failingEndpoint == url.lastPathComponent || body == nil ? 404 : 200)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

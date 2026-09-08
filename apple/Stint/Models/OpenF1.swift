import Foundation
import CryptoKit

/// Historical OpenF1 requests are unauthenticated, limited to 30/minute.
/// Endpoint schemas: https://openf1.org/docs/
actor OpenF1Client {
    private let session: URLSession
    private let baseURL: URL
    private let requestSpacing: TimeInterval
    private let retryDelay: TimeInterval
    private let cacheDirectory: URL?
    private var nextRequest = Date.distantPast

    static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Stint/OpenF1", isDirectory: true)
    }

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://api.openf1.org/v1")!,
         requestSpacing: TimeInterval = 2.1, retryDelay: TimeInterval = 5,
         cacheDirectory: URL? = OpenF1Client.defaultCacheDirectory) {
        self.session = session
        self.baseURL = baseURL
        self.requestSpacing = requestSpacing
        self.retryDelay = retryDelay
        self.cacheDirectory = cacheDirectory
    }

    func get<T: Decodable>(_ endpoint: String, query: [String: String]) async throws -> [T] {
        try Task.checkCancellation()
        let url = requestURL(endpoint, query: query)
        // Keep successful historical responses so a retry resumes after the failed request.
        // Session discovery stays fresh; empty and rejected location feeds are never retained.
        let cache = query["session_key"] == nil ? nil : cacheURL(url)
        if let cache, let modified = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 86_400, let data = try? Data(contentsOf: cache),
           let result = try? Self.decoder().decode([T].self, from: data) {
            return result
        }
        for attempt in 0..<4 {
            let slot = max(Date(), nextRequest)
            nextRequest = slot.addingTimeInterval(requestSpacing)
            let delay = slot.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.timeoutInterval = 120
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch let error as URLError where attempt < 3 && [
                .timedOut, .networkConnectionLost, .notConnectedToInternet,
                .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
            ].contains(error.code) {
                try await Task.sleep(for: .seconds(retryDelay * pow(2, Double(attempt))))
                continue
            }
            guard let response = response as? HTTPURLResponse else { throw ReplayError.invalid("OpenF1 returned an invalid response.") }
            if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                guard attempt < 3 else { throw ReplayError.invalid("OpenF1 is busy. Retry the download to continue from the data already downloaded.") }
                let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? retryDelay * pow(2, Double(attempt))
                // Reserve the next slot too, so other requests on this client respect the backoff.
                nextRequest = max(nextRequest, Date().addingTimeInterval(max(0, retry)))
                continue
            }
            if response.statusCode == 404,
               (try? JSONDecoder().decode(APIError.self, from: data).detail) == "No results found." {
                return []
            }
            guard response.statusCode == 200 else {
                if [401, 403].contains(response.statusCode) {
                    throw ReplayError.invalid("This race is not available as a free historical replay yet. Try again at least 30 minutes after the session ends.")
                }
                throw ReplayError.invalid("OpenF1 couldn’t provide \(endpoint) (HTTP \(response.statusCode)). Try again later.")
            }
            guard data.count <= 100_000_000 else { throw ReplayError.invalid("The OpenF1 response is too large to load.") }
            let result = try Self.decoder().decode([T].self, from: data)
            if !result.isEmpty, let cache {
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
                trimCache()
            }
            return result
        }
        throw ReplayError.invalid("OpenF1 is unavailable. Try again later.")
    }

    func invalidate(_ endpoint: String, query: [String: String]) {
        if let cache = cacheURL(requestURL(endpoint, query: query)) { try? FileManager.default.removeItem(at: cache) }
    }

    private struct APIError: Decodable { let detail: String }

    private func requestURL(_ endpoint: String, query: [String: String]) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private func cacheURL(_ url: URL) -> URL? {
        let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent(key + ".json")
    }

    private func trimCache() {
        guard let cacheDirectory, let files = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { return }
        let entries = files.compactMap { url -> (url: URL, date: Date, size: Int)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = values.contentModificationDate, let size = values.fileSize else { return nil }
            return (url, date, size)
        }.sorted { $0.date > $1.date }
        var bytes = 0
        for entry in entries {
            bytes += entry.size
            if Date().timeIntervalSince(entry.date) >= 86_400 || bytes > 512_000_000 {
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard let date = (try? fractional.parse(value)) ?? (try? whole.parse(value)) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid OpenF1 timestamp")
            }
            return date
        }
        return decoder
    }
}

enum OpenF1 {
    struct Session: Codable {
        let sessionKey: Int
        let sessionName: String
        let dateStart: Date
        let dateEnd: Date
        let circuitShortName: String
        let year: Int
        let isCancelled: Bool?

        func matches(_ race: SeasonRace) -> Bool {
            let end = race.calendar.date(byAdding: .day, value: 1, to: race.endDate)!
            let names = [race.circuit.title, race.circuitID] + (Self.aliases[race.circuitID] ?? [])
            return year == 2026 && sessionName == "Race" && isCancelled != true
                && dateStart >= race.startDate && dateStart < end
                && names.contains { Self.normalized($0) == Self.normalized(circuitShortName) }
        }

        private static func normalized(_ value: String) -> String {
            value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber }
        }
        private static let aliases: [String: [String]] = [
            "barcelona": ["Catalunya", "Barcelona-Catalunya"], "spielberg": ["Spielberg", "Red Bull Ring"],
            "spafrancorchamps": ["Spa-Francorchamps", "Spa"], "budapest": ["Hungaroring"],
            "mexicocity": ["Mexico City", "Mexico"], "interlagos": ["São Paulo", "Interlagos"],
            "yasmarina": ["Yas Marina Circuit", "Yas Marina", "Abu Dhabi"], "lusail": ["Lusail", "Losail"],
            "austin": ["Austin", "Circuit of the Americas"], "montreal": ["Montreal", "Montréal"],
            "monaco": ["Monte Carlo"], "sepang": ["Sepang", "Kuala Lumpur"], "madrid": ["Madring", "Madrid"]
        ]
    }
    struct DriverInfo: Decodable {
        let driverNumber: Int
        let fullName: String?
        let nameAcronym: String?
        let teamColour: String?
        let teamName: String?
        var driver: Driver {
            let color = teamColour ?? "A7A7A7"
            return Driver(id: nameAcronym.flatMap { $0.isEmpty ? nil : $0 } ?? String(driverNumber),
                          name: fullName ?? "Driver \(driverNumber)", number: driverNumber,
                          color: color.range(of: "^[0-9A-Fa-f]{6}$", options: .regularExpression) == nil ? "#A7A7A7" : "#\(color)", team: teamName)
        }
    }
    struct Location: Decodable {
        let date: Date
        let x: Double
        let y: Double
        var vector: SIMD2<Double> { SIMD2(x, y) }
    }
    struct CarData: Decodable {
        let date: Date
        let speed: Double?
        let throttle: Double?
        let brake: Double?
        let drs: Int?
        let nGear: Int?
        let rpm: Int?
    }
    struct Position: Decodable {
        let date: Date
        let driverNumber: Int
        let position: Int
    }
    struct Interval: Decodable {
        let date: Date
        let driverNumber: Int
        let gapToLeader: Gap?
        enum Gap: Decodable {
            case seconds(Double), laps(String)
            init(from decoder: Decoder) throws {
                let value = try decoder.singleValueContainer()
                if let number = try? value.decode(Double.self) { self = .seconds(number) }
                else { self = .laps(try value.decode(String.self)) }
            }
            var seconds: Double? { if case .seconds(let value) = self { return value }; return nil }
        }
    }
    struct Lap: Decodable {
        let driverNumber: Int
        let lapNumber: Int
        let dateStart: Date?
        let lapDuration: Double?
        let isPitOutLap: Bool?
    }
    struct Stint: Decodable {
        let driverNumber: Int
        let lapStart: Int?
        let compound: String?
    }
}

enum OpenF1DownloadError: LocalizedError {
    case incompleteLocations(String)
    case noUsableLocations
    var errorDescription: String? {
        switch self {
        case .incompleteLocations(let driver):
            "OpenF1’s car-location data for \(driver) doesn’t cover the recorded race yet. No partial replay was saved. Please try again later."
        case .noUsableLocations:
            "This race has no complete, usable car-location feed. A map replay can’t be saved from the available data."
        }
    }
}

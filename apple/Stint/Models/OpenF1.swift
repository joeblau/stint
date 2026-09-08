import Foundation

/// Historical OpenF1 requests are unauthenticated, limited to 30/minute.
/// Endpoint schemas: https://openf1.org/docs/
actor OpenF1Client {
    private let session: URLSession
    private let baseURL: URL
    private let requestSpacing: TimeInterval
    private var nextRequest = Date.distantPast

    init(session: URLSession = .shared, baseURL: URL = URL(string: "https://api.openf1.org/v1")!, requestSpacing: TimeInterval = 2.1) {
        self.session = session
        self.baseURL = baseURL
        self.requestSpacing = requestSpacing
    }

    func get<T: Decodable>(_ endpoint: String, query: [String: String]) async throws -> [T] {
        var components = URLComponents(url: baseURL.appendingPathComponent(endpoint), resolvingAgainstBaseURL: false)!
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        for attempt in 0..<3 {
            let slot = max(Date(), nextRequest)
            nextRequest = slot.addingTimeInterval(requestSpacing)
            let delay = slot.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
            try Task.checkCancellation()
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 120
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw ReplayError.invalid("OpenF1 returned an invalid response.") }
            if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                guard attempt < 2 else { throw ReplayError.invalid("OpenF1 is busy. Please try the download again shortly.") }
                let retry = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(5 * (attempt + 1))
                try await Task.sleep(for: .seconds(min(60, max(2.1, retry))))
                continue
            }
            guard response.statusCode == 200 else {
                if [401, 403].contains(response.statusCode) {
                    throw ReplayError.invalid("This race is not available as a free historical replay yet. Try again at least 30 minutes after the session ends.")
                }
                throw ReplayError.invalid("OpenF1 couldn’t provide \(endpoint) (HTTP \(response.statusCode)). Try again later.")
            }
            guard data.count <= 100_000_000 else { throw ReplayError.invalid("The OpenF1 response is too large to load.") }
            return try Self.decoder().decode([T].self, from: data)
        }
        throw ReplayError.invalid("OpenF1 is unavailable. Try again later.")
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
    var errorDescription: String? {
        switch self {
        case .incompleteLocations(let driver):
            "OpenF1’s car-location data for \(driver) doesn’t cover the recorded race yet. No partial replay was saved. Please try again later."
        }
    }
}

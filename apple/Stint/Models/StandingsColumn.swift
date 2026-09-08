import Foundation

/// The value shown in the last column of the standings list.
enum StandingsColumn: String, CaseIterable, Identifiable, Codable {
    case time, gap, interval, tyres, sectors, best, pit, diff, laps
    var id: String { rawValue }

    var title: String {
        switch self {
        case .time: "Time"
        case .gap: "Gap"
        case .interval: "Interval"
        case .tyres: "Tyres"
        case .sectors: "Sectors"
        case .best: "Best"
        case .pit: "Pit"
        case .diff: "Diff"
        case .laps: "Laps"
        }
    }

    var detail: String {
        switch self {
        case .time: "Last lap time"
        case .gap: "Time behind the leader"
        case .interval: "Time to the car ahead"
        case .tyres: "Compound and laps on this set"
        case .sectors: "S1, S2, S3 of the latest lap"
        case .best: "Personal best lap"
        case .pit: "Pit lane status and last stop"
        case .diff: "Positions gained or lost from the grid"
        case .laps: "Laps completed"
        }
    }

    var symbol: String {
        switch self {
        case .time: "stopwatch"
        case .gap: "flag.checkered"
        case .interval: "arrow.left.and.right"
        case .tyres: "tire"
        case .sectors: "rectangle.split.3x1"
        case .best: "trophy"
        case .pit: "wrench.and.screwdriver"
        case .diff: "arrow.up.arrow.down"
        case .laps: "arrow.2.circlepath"
        }
    }

    static let favoriteCount = 4
    static let defaultOrder: [StandingsColumn] = [.gap, .interval, .tyres, .time, .sectors, .best, .pit, .diff, .laps]

    /// Restores a persisted order, dropping unknown entries and appending any columns added since.
    static func order(from stored: String) -> [StandingsColumn] {
        var order = stored.split(separator: ",").compactMap { StandingsColumn(rawValue: String($0)) }
        var seen = Set<StandingsColumn>()
        order = order.filter { seen.insert($0).inserted }
        order += defaultOrder.filter { !seen.contains($0) }
        return order
    }

    static func stored(_ order: [StandingsColumn]) -> String { order.map(\.rawValue).joined(separator: ",") }
}

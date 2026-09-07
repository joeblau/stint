import Foundation

struct SeasonRace: Identifiable, Equatable {
    let round: Int
    let name: String
    let circuitID: String
    let startMonth: Int
    let startDay: Int
    let endMonth: Int
    let endDay: Int
    let timeZoneID: String
    let point: GeoPoint
    var id: Int { round }
    var circuit: DemoCircuit { DemoCircuit.allCases.first { $0.id == circuitID }! }
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneID)!
        return value
    }
    var startDate: Date { calendar.date(from: DateComponents(year: 2026, month: startMonth, day: startDay))! }
    var endDate: Date { calendar.date(from: DateComponents(year: 2026, month: endMonth, day: endDay))! }
    func isCompleted(at date: Date) -> Bool { date >= calendar.date(byAdding: .day, value: 1, to: endDate)! }
    func status(at date: Date) -> String {
        isCompleted(at: date) ? "Completed" : date >= startDate ? "Race weekend" : "Upcoming"
    }
    var dateLabel: String {
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return startMonth == endMonth ? "\(startDay)–\(endDay) \(months[endMonth])" : "\(startDay) \(months[startMonth])–\(endDay) \(months[endMonth])"
    }
    func includes(month: Int, day: Int) -> Bool {
        let value = month * 100 + day
        return value >= startMonth * 100 + startDay && value <= endMonth * 100 + endDay
    }
}

enum Season2026 {
    // Official calendar snapshot, September 7, 2026: https://www.formula1.com/en/racing/2026
    // Dates are race-weekend dates in each venue's local time zone.
    static let races: [SeasonRace] = [
        SeasonRace(round: 1, name: "Australia", circuitID: "melbourne", startMonth: 3, startDay: 6, endMonth: 3, endDay: 8, timeZoneID: "Australia/Melbourne", point: GeoPoint(latitude: -37.849757, longitude: 144.968644)),
        SeasonRace(round: 2, name: "China", circuitID: "shanghai", startMonth: 3, startDay: 13, endMonth: 3, endDay: 15, timeZoneID: "Asia/Shanghai", point: GeoPoint(latitude: 31.336835, longitude: 121.21838)),
        SeasonRace(round: 3, name: "Japan", circuitID: "suzuka", startMonth: 3, startDay: 27, endMonth: 3, endDay: 29, timeZoneID: "Asia/Tokyo", point: GeoPoint(latitude: 34.843344, longitude: 136.540283)),
        SeasonRace(round: 4, name: "Miami", circuitID: "miami", startMonth: 5, startDay: 1, endMonth: 5, endDay: 3, timeZoneID: "America/New_York", point: GeoPoint(latitude: 25.959092, longitude: -80.237371)),
        SeasonRace(round: 5, name: "Canada", circuitID: "montreal", startMonth: 5, startDay: 22, endMonth: 5, endDay: 24, timeZoneID: "America/Toronto", point: GeoPoint(latitude: 45.501816, longitude: -73.523246)),
        SeasonRace(round: 6, name: "Monaco", circuitID: "monaco", startMonth: 6, startDay: 5, endMonth: 6, endDay: 7, timeZoneID: "Europe/Monaco", point: GeoPoint(latitude: 43.739404, longitude: 7.427191)),
        SeasonRace(round: 7, name: "Barcelona-Catalunya", circuitID: "barcelona", startMonth: 6, startDay: 12, endMonth: 6, endDay: 14, timeZoneID: "Europe/Madrid", point: GeoPoint(latitude: 41.570034, longitude: 2.261221)),
        SeasonRace(round: 8, name: "Austria", circuitID: "spielberg", startMonth: 6, startDay: 26, endMonth: 6, endDay: 28, timeZoneID: "Europe/Vienna", point: GeoPoint(latitude: 47.220023, longitude: 14.765119)),
        SeasonRace(round: 9, name: "Great Britain", circuitID: "silverstone", startMonth: 7, startDay: 3, endMonth: 7, endDay: 5, timeZoneID: "Europe/London", point: GeoPoint(latitude: 52.07879, longitude: -1.015349)),
        SeasonRace(round: 10, name: "Belgium", circuitID: "spafrancorchamps", startMonth: 7, startDay: 17, endMonth: 7, endDay: 19, timeZoneID: "Europe/Brussels", point: GeoPoint(latitude: 50.444251, longitude: 5.96502)),
        SeasonRace(round: 11, name: "Hungary", circuitID: "budapest", startMonth: 7, startDay: 24, endMonth: 7, endDay: 26, timeZoneID: "Europe/Budapest", point: GeoPoint(latitude: 47.58026, longitude: 19.245888)),
        SeasonRace(round: 12, name: "Netherlands", circuitID: "zandvoort", startMonth: 8, startDay: 21, endMonth: 8, endDay: 23, timeZoneID: "Europe/Amsterdam", point: GeoPoint(latitude: 52.388408, longitude: 4.540491)),
        SeasonRace(round: 13, name: "Italy", circuitID: "monza", startMonth: 9, startDay: 4, endMonth: 9, endDay: 6, timeZoneID: "Europe/Rome", point: GeoPoint(latitude: 45.618975, longitude: 9.281223)),
        SeasonRace(round: 14, name: "Spain", circuitID: "madrid", startMonth: 9, startDay: 11, endMonth: 9, endDay: 13, timeZoneID: "Europe/Madrid", point: GeoPoint(latitude: 40.465178, longitude: -3.616887)),
        SeasonRace(round: 15, name: "Azerbaijan", circuitID: "baku", startMonth: 9, startDay: 24, endMonth: 9, endDay: 26, timeZoneID: "Asia/Baku", point: GeoPoint(latitude: 40.372688, longitude: 49.853247)),
        SeasonRace(round: 16, name: "Bahrain · Malaysia", circuitID: "sepang", startMonth: 10, startDay: 2, endMonth: 10, endDay: 4, timeZoneID: "Asia/Kuala_Lumpur", point: GeoPoint(latitude: 2.760529, longitude: 101.735641)),
        SeasonRace(round: 17, name: "Singapore", circuitID: "singapore", startMonth: 10, startDay: 9, endMonth: 10, endDay: 11, timeZoneID: "Asia/Singapore", point: GeoPoint(latitude: 1.291728, longitude: 103.864144)),
        SeasonRace(round: 18, name: "United States", circuitID: "austin", startMonth: 10, startDay: 23, endMonth: 10, endDay: 25, timeZoneID: "America/Chicago", point: GeoPoint(latitude: 30.13176, longitude: -97.639651)),
        SeasonRace(round: 19, name: "Mexico", circuitID: "mexicocity", startMonth: 10, startDay: 30, endMonth: 11, endDay: 1, timeZoneID: "America/Mexico_City", point: GeoPoint(latitude: 19.406226, longitude: -99.094338)),
        SeasonRace(round: 20, name: "Brazil", circuitID: "interlagos", startMonth: 11, startDay: 6, endMonth: 11, endDay: 8, timeZoneID: "America/Sao_Paulo", point: GeoPoint(latitude: -23.703744, longitude: -46.699905)),
        SeasonRace(round: 21, name: "Las Vegas", circuitID: "lasvegas", startMonth: 11, startDay: 19, endMonth: 11, endDay: 21, timeZoneID: "America/Los_Angeles", point: GeoPoint(latitude: 36.109904, longitude: -115.161202)),
        SeasonRace(round: 22, name: "Qatar", circuitID: "lusail", startMonth: 11, startDay: 27, endMonth: 11, endDay: 29, timeZoneID: "Asia/Qatar", point: GeoPoint(latitude: 25.489077, longitude: 51.449681)),
        SeasonRace(round: 23, name: "Abu Dhabi", circuitID: "yasmarina", startMonth: 12, startDay: 4, endMonth: 12, endDay: 6, timeZoneID: "Asia/Dubai", point: GeoPoint(latitude: 24.46997, longitude: 54.605463)),
    ]
    static func nextRace(at date: Date) -> SeasonRace? { races.first { !$0.isCompleted(at: date) } }
}

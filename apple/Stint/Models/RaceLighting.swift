import Foundation

enum RaceLighting: String, CaseIterable, Identifiable {
    case day = "Day", night = "Night", raceTime = "Race time"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .day: "sun.max.fill"
        case .night: "moon.fill"
        case .raceTime: "clock.fill"
        }
    }

    func isDay(at date: Date, point: GeoPoint) -> Bool {
        switch self {
        case .day: true
        case .night: false
        case .raceTime: Self.solarElevation(at: date, point: point) > -0.833
        }
    }

    // NOAA's approximate solar-position equations, evaluated in UTC so daylight saving
    // and the Mac/iPad's own time zone cannot change lighting at the circuit.
    // https://gml.noaa.gov/grad/solcalc/solareqns.PDF
    static func solarElevation(at date: Date, point: GeoPoint) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Double(calendar.ordinality(of: .day, in: .year, for: date)!)
        let days = Double(calendar.range(of: .day, in: .year, for: date)!.count)
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        let minutes = Double(parts.hour! * 60 + parts.minute!) + Double(parts.second!) / 60
        let gamma = 2 * Double.pi / days * (day - 1 + (minutes / 60 - 12) / 24)
        let equation = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                                - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)
        let hourAngle = ((minutes + equation + 4 * point.longitude) / 4 - 180) * .pi / 180
        let latitude = point.latitude * .pi / 180
        let sine = sin(latitude) * sin(declination) + cos(latitude) * cos(declination) * cos(hourAngle)
        return asin(min(1, max(-1, sine))) * 180 / .pi
    }
}

extension SeasonRace {
    // Published local start times; relocated Sepang has no time in this snapshot.
    // https://www.formula1.com/en/latest/article/official-grand-prix-start-times-for-2026-f1-season-confirmed.2UgPfArqH76tzlOYh21jSG.2UgPfArqH76tzlOYh21jSG
    var raceStartHour: Int? {
        switch circuitID {
        case "sepang": nil
        case "suzuka", "mexicocity", "interlagos": 14
        case "miami", "montreal": 16
        case "yasmarina": 17
        case "lusail": 19
        case "singapore", "lasvegas": 20
        default: 15
        }
    }
    var lightingStartDate: Date {
        calendar.date(bySettingHour: raceStartHour ?? 15, minute: 0, second: 0, of: endDate)!
    }
}

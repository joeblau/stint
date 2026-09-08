import XCTest
@testable import Stint

final class Season2026Tests: XCTestCase {
    func testOrderedCalendarUsesValidDistinctCircuitsAndLocalWeekendDates() throws {
        let races = Season2026.races
        XCTAssertEqual(races.map(\.round), Array(1...23))
        XCTAssertEqual(Set(races.map(\.circuitID)).count, races.count)
        XCTAssertEqual(Set(races.map(\.circuitID)), Set(DemoCircuit.allCases.filter(\.is2026).map(\.id)))
        for (a, b) in zip(races, races.dropFirst()) { XCTAssertLessThan(a.endDate, b.startDate) }
        for race in races {
            XCTAssertNotNil(TimeZone(identifier: race.timeZoneID))
            XCTAssertTrue(race.point.isValid)
            XCTAssertLessThan(race.startDate, race.endDate)
            XCTAssertFalse(race.isCompleted(at: race.endDate))
            XCTAssertTrue(race.isCompleted(at: race.calendar.date(byAdding: .day, value: 1, to: race.endDate)!))
        }
    }

    func testSeptemberProgressAndCrossMonthWeekend() throws {
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-07T12:00:00Z"))
        XCTAssertEqual(Season2026.races.filter { $0.isCompleted(at: date) }.count, 13)
        XCTAssertEqual(Season2026.nextRace(at: date)?.circuitID, "madrid")
        let mexico = try XCTUnwrap(Season2026.races.first { $0.circuitID == "mexicocity" })
        XCTAssertTrue(mexico.includes(month: 10, day: 30))
        XCTAssertTrue(mexico.includes(month: 10, day: 31))
        XCTAssertTrue(mexico.includes(month: 11, day: 1))
        XCTAssertFalse(mexico.includes(month: 11, day: 2))
        XCTAssertEqual(mexico.dateLabel, "30 Oct–1 Nov")
    }
}

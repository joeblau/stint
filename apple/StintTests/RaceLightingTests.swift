import XCTest
@testable import Stint

final class RaceLightingTests: XCTestCase {
    @MainActor func testSelectingRaceResetsLightingToScheduledRaceTime() throws {
        let session = RaceSession()
        XCTAssertEqual(session.lighting, .raceTime)
        XCTAssertTrue(session.lightingIsDay)
        session.lighting = .day
        session.loadDemo(try XCTUnwrap(DemoCircuit.allCases.first { $0.id == "singapore" }))
        XCTAssertEqual(session.lighting, .raceTime)
        XCTAssertFalse(session.lightingIsDay)
        session.lighting = .night
        session.loadDemo(.monaco)
        XCTAssertEqual(session.lighting, .raceTime)
        XCTAssertTrue(session.lightingIsDay)
        XCTAssertEqual(session.lightingTimeLabel, "Race time · 15:00 local")
    }

    func testScheduledDayAndNightRacesUseVenueTimeZone() throws {
        for (id, expectedDay) in [("monaco", true), ("melbourne", true), ("singapore", false), ("lasvegas", false), ("lusail", false)] {
            let race = try XCTUnwrap(Season2026.races.first { $0.circuitID == id })
            XCTAssertEqual(RaceLighting.raceTime.isDay(at: race.lightingStartDate, point: race.point), expectedDay, id)
            XCTAssertTrue(RaceLighting.day.isDay(at: race.lightingStartDate, point: race.point))
            XCTAssertFalse(RaceLighting.night.isDay(at: race.lightingStartDate, point: race.point))
        }
    }

    @MainActor func testRaceTimeTracksReplaySunsetAndSeeking() throws {
        let session = RaceSession()
        session.loadDemo(try XCTUnwrap(DemoCircuit.allCases.first { $0.id == "yasmarina" }))
        session.lighting = .raceTime
        XCTAssertTrue(session.lightingIsDay)
        session.time = 3600
        XCTAssertFalse(session.lightingIsDay)
        session.time = 0
        XCTAssertTrue(session.lightingIsDay)
        session.lighting = .night
        XCTAssertFalse(session.lightingIsDay)
    }

    @MainActor func testUnknownStartTimeIsLabeledAsDemo() throws {
        let session = RaceSession()
        session.loadDemo(try XCTUnwrap(DemoCircuit.allCases.first { $0.id == "sepang" }))
        session.lighting = .raceTime
        XCTAssertTrue(session.lightingTimeLabel.hasPrefix("Demo time"))
        XCTAssertTrue(session.lightingIsDay)
    }
}

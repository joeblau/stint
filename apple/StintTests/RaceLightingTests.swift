import XCTest
import AppKit
@testable import Stint

final class RaceLightingTests: XCTestCase {
    @MainActor func testPausedDayNightTransitionKeepsSceneRenderingUntilFinished() async throws {
        let session = RaceSession()
        session.isPlaying = false
        session.lighting = .day
        let surface = RaceMapSurface(session: session)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = surface
        surface.layout()
        surface.displayFrame(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertFalse(surface.isRenderingContinuously)
        session.lighting = .night
        surface.requestUpdate()
        surface.displayFrame(at: ProcessInfo.processInfo.systemUptime)
        XCTAssertTrue(surface.isRenderingContinuously)
        let deadline = Date().addingTimeInterval(6)
        while surface.isRenderingContinuously && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(surface.isRenderingContinuously)
        XCTAssertEqual(surface.map.appearance?.name, .darkAqua)
        XCTAssertEqual(session.time, 0)
        XCTAssertEqual(session.renderTime, 0)
        XCTAssertFalse(session.isPlaying)
        surface.setActive(false)
        window.contentView = nil
    }

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

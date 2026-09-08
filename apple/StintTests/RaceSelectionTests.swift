import XCTest
@testable import Stint

final class RaceSelectionTests: XCTestCase {
    @MainActor func testFollowingAndSelectedDriverSurviveCircuitSwitch() {
        let session = RaceSession()
        session.selectedDriverID = "HAM"
        session.toggleFollow()
        session.loadDemo(.monza)
        XCTAssertTrue(session.followsDriver)
        XCTAssertEqual(session.selectedDriverID, "HAM")
        XCTAssertEqual(session.demoCircuit, .monza)
        session.overview()
        session.loadDemo(.silverstone)
        XCTAssertFalse(session.followsDriver)
        XCTAssertEqual(session.selectedDriverID, "HAM")
    }

    @MainActor func testMissingDriverFallsBackWithoutChangingCameraMode() throws {
        let session = RaceSession()
        session.selectedDriverID = "HAM"
        session.toggleFollow()
        let demo = try DemoCircuit.monza.load()
        let oneDriver = RaceReplay(version: demo.version, title: "One driver", circuit: demo.circuit,
                                   recordings: [demo.recordings[0]])
        session.install(oneDriver, source: "IMPORTED REPLAY")
        XCTAssertTrue(session.followsDriver)
        XCTAssertEqual(session.selectedDriverID, oneDriver.recordings[0].driver.id)
    }
}

import XCTest
@testable import Stint

final class AppLaunchTrackerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppLaunchTrackerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFirstLaunchShowsOnboarding() {
        let tracker = AppLaunchTracker(defaults: defaults)
        tracker.recordLaunch()
        XCTAssertEqual(tracker.launchCount, 1)
        XCTAssertTrue(tracker.shouldShowOnboarding)
    }

    func testCompletingOnboardingHidesCard() {
        let tracker = AppLaunchTracker(defaults: defaults)
        tracker.recordLaunch()
        tracker.completeOnboarding()
        XCTAssertFalse(tracker.shouldShowOnboarding)
    }

    func testSecondLaunchAfterCompletingOnboardingStaysHidden() {
        let first = AppLaunchTracker(defaults: defaults)
        first.recordLaunch()
        first.completeOnboarding()
        let second = AppLaunchTracker(defaults: defaults)
        second.recordLaunch()
        XCTAssertEqual(second.launchCount, 2)
        XCTAssertFalse(second.shouldShowOnboarding)
    }

    func testSecondLaunchWithoutCompletingOnboardingStaysHidden() {
        let first = AppLaunchTracker(defaults: defaults)
        first.recordLaunch()
        let second = AppLaunchTracker(defaults: defaults)
        second.recordLaunch()
        XCTAssertEqual(second.launchCount, 2)
        XCTAssertFalse(second.shouldShowOnboarding)
    }
}

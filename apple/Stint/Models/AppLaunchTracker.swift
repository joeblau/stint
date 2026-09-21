import Foundation
import Observation

@Observable
final class AppLaunchTracker {
    private(set) var launchCount: Int
    private(set) var onboardingCompleted: Bool
    @ObservationIgnored private let defaults: UserDefaults

    static let launchCountKey = "app-launch-count"
    static let onboardingCompletedKey = "onboarding-completed"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        launchCount = defaults.integer(forKey: Self.launchCountKey)
        onboardingCompleted = defaults.bool(forKey: Self.onboardingCompletedKey)
    }

    var shouldShowOnboarding: Bool { launchCount == 1 && !onboardingCompleted }

    func recordLaunch() {
        launchCount += 1
        defaults.set(launchCount, forKey: Self.launchCountKey)
    }

    func completeOnboarding() {
        onboardingCompleted = true
        defaults.set(true, forKey: Self.onboardingCompletedKey)
    }
}

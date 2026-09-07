import Foundation

/// Smooth heading changes through north using the shortest turn, independent of frame rate.
struct FollowCamera {
    // Ask MapKit for its closest, lowest view. MapKit clamps these requests to
    // the supported camera range for the current map and location.
    // Requests below 10 m can force MapKit into its overhead-only camera range.
    static let chaseDistance: Double = 10
    static let chasePitch: Double = 89.9

    private(set) var heading: Double?

    mutating func reset() { heading = nil }

    mutating func update(target: Double, elapsed: Double, snap: Bool = false) -> Double {
        guard let current = heading, !snap else {
            heading = target
            return target
        }
        let turn = (target - current + 540).truncatingRemainder(dividingBy: 360) - 180
        let fraction = 1 - exp(-max(0, elapsed) / 0.18)
        let next = (current + turn * fraction + 360).truncatingRemainder(dividingBy: 360)
        heading = next
        return next
    }
}

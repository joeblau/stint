import Foundation
import Observation

@MainActor @Observable
final class OverlayVisibility {
    private(set) var isVisible = true
    @ObservationIgnored private var lastInteraction: TimeInterval
    static let idleInterval: TimeInterval = 5

    init(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { lastInteraction = now }

    func reveal(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastInteraction = now
        if !isVisible { isVisible = true }
    }

    func update(at now: TimeInterval, isInteracting: Bool, autoHideEnabled: Bool = true) {
        if isInteracting || !autoHideEnabled { reveal(at: now) }
        else if isVisible && now - lastInteraction >= Self.idleInterval { isVisible = false }
    }
}

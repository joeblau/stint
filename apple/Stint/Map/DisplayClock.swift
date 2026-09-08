import QuartzCore

/// One display-synchronized callback, with a weak target so detached views cannot
/// be retained by the run loop. Both platforms use their window's native display.
@MainActor
final class DisplayClock {
    private final class Target: NSObject {
        var tick: ((TimeInterval) -> Void)?
        @objc func frame(_ link: CADisplayLink) { tick?(link.targetTimestamp) }
    }
    private let target = Target()
    private var link: CADisplayLink?

    func start(in view: PlatformView, tick: @escaping (TimeInterval) -> Void) {
        guard link == nil, view.window != nil else { return }
        target.tick = tick
        #if os(macOS)
        let link = view.displayLink(target: target, selector: #selector(Target.frame(_:)))
        #else
        let link = CADisplayLink(target: target, selector: #selector(Target.frame(_:)))
        #endif
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        target.tick = nil
    }

    deinit { link?.invalidate() }
}

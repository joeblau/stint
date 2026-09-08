import Foundation

/// Filters timing jitter along the recorded polyline, without averaging coordinates
/// across corners. This is a playback-only index; source samples remain unchanged.
struct ReplayMotion {
    private let distances: [Double]
    private let integrals: [Double]
    private let spanForSegment: [Int]
    private let spans: [ClosedRange<Int>]
    private static let halfWindow = 0.5

    init(samples: [PositionSample]) {
        var distances = [0.0]
        var integrals = [0.0]
        var spanForSegment = Array(repeating: -1, count: samples.count)
        var spans: [ClosedRange<Int>] = []
        var start: Int?
        for index in 0..<max(0, samples.count - 1) {
            let a = samples[index], b = samples[index + 1]
            let longitude = (b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180
            let dx = longitude * cos((a.latitude + b.latitude) * .pi / 360) * 111_320
            let dy = (b.latitude - a.latitude) * 111_320
            let distance = hypot(dx, dy)
            let elapsed = b.time - a.time
            distances.append(distances[index] + distance)
            integrals.append(integrals[index] + (distances[index] + distances[index + 1]) * elapsed / 2)
            // Keep actual stops and feed outages as boundaries. Never smooth across them.
            let moving = elapsed > 0 && elapsed <= 1 && distance > 0.001
                && a.speedKPH.map { $0 > 1 } != false && b.speedKPH.map { $0 > 1 } != false
            if moving {
                if start == nil { start = index }
                spanForSegment[index] = spans.count
            } else if let first = start {
                spans.append(first...index)
                start = nil
            }
        }
        if let start { spans.append(start...(samples.count - 1)) }
        self.distances = distances
        self.integrals = integrals
        self.spanForSegment = spanForSegment
        self.spans = spans
    }

    func location(at time: Double, segment: Int, samples: [PositionSample]) -> (index: Int, fraction: Double)? {
        guard samples.count >= 2, time > samples[0].time, time < samples[samples.count - 1].time,
              spanForSegment[segment] >= 0 else { return nil }
        let span = spans[spanForSegment[segment]]
        let first = span.lowerBound, last = span.upperBound
        let begin = samples[first].time, end = samples[last].time
        let window = min(Self.halfWindow, (end - begin) / 2)
        guard window > 0 else { return nil }

        func integral(at time: Double) -> Double {
            var low = first, high = last
            while low + 1 < high {
                let mid = (low + high) / 2
                if samples[mid].time <= time { low = mid } else { high = mid }
            }
            let elapsed = time - samples[low].time
            let velocity = (distances[high] - distances[low]) / (samples[high].time - samples[low].time)
            return integrals[low] + distances[low] * elapsed + velocity * elapsed * elapsed / 2
        }
        func extendedIntegral(at time: Double) -> Double {
            // Reflect distance about each endpoint. This preserves arrival/departure
            // times and constant-speed motion, with no endpoint drift or overshoot.
            if time < begin { return 2 * distances[first] * (time - begin) + integral(at: 2 * begin - time) }
            if time > end { return 2 * distances[last] * (time - end) + integral(at: 2 * end - time) }
            return integral(at: time)
        }
        let distance = min(distances[last], max(distances[first],
            (extendedIntegral(at: time + window) - extendedIntegral(at: time - window)) / (2 * window)))
        var low = first, high = last
        while low + 1 < high {
            let mid = (low + high) / 2
            if distances[mid] <= distance { low = mid } else { high = mid }
        }
        return (low, (distance - distances[low]) / (distances[high] - distances[low]))
    }
}

import SwiftUI

enum GaugeSpeedUnit: String {
    case kph, mph
    var label: String { self == .kph ? "KM/H" : "MPH" }
    var spokenLabel: String { self == .kph ? "kilometers per hour" : "miles per hour" }
    /// F1 cars peak near 350–360 km/h (Monza, Baku), so both scales top out there: 360 km/h ≈ 224 mph.
    var maximum: Double { self == .kph ? 360 : 225 }
    var tickStep: Double { self == .kph ? 60 : 45 }
    func value(fromKPH speed: Double) -> Double { self == .kph ? speed : speed / 1.609344 }
}

struct TelemetryGaugeView: View {
    let telemetry: Telemetry
    var diameter: CGFloat = 210
    @AppStorage("telemetry-speed-unit") private var unit = GaugeSpeedUnit.kph
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Environment(\.colorScheme) private var colorScheme

    private var ink: Color { colorScheme == .dark ? StintPalette.white : StintPalette.trackBlack }
    private var speedInk: Color { colorScheme == .dark ? StintPalette.trackBlack : StintPalette.white }
    private var speedGradient: AngularGradient { AngularGradient(
        colors: colorScheme == .dark
            ? [StintPalette.pitGray, Color(hex: "#D2D2D2"), StintPalette.white]
            : [StintPalette.pitGray, StintPalette.asphalt, StintPalette.trackBlack],
        center: .center, startAngle: .degrees(135), endAngle: .degrees(405)) }
    private static let throttleGradient = AngularGradient(
        colors: [Color(hex: "#28734B"), StintPalette.telemetryActive, Color(hex: "#B7E9CA")],
        center: .center, startAngle: .degrees(135), endAngle: .degrees(263))
    private static let red = StintPalette.red
    private static let scaleStart = 135.0
    private static let scaleSweep = 270.0
    private var speed: Double? { telemetry.speedKPH.map { unit.value(fromKPH: $0) } }
    private var speedFraction: Double { min(1, max(0, (speed ?? 0) / unit.maximum)) }
    private var throttle: Double { min(1, max(0, telemetry.throttle)) }
    private var brake: Double { min(1, max(0, telemetry.brake)) }

    var body: some View {
        ZStack {
            arc(start: 135, end: 405, radius: 0.444, width: 0.09, color: ink.opacity(0.16))
            arc(start: 135, end: 135 + 270 * speedFraction, radius: 0.444, width: 0.09, color: speedGradient)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: speedFraction)

            // Independent pedal tracks, both filling from the bottom toward the top.
            arc(start: 135, end: 263, radius: 0.342, width: 0.07, color: ink.opacity(0.14))
            arc(start: 277, end: 405, radius: 0.342, width: 0.07, color: ink.opacity(0.14))
            arc(start: 135, end: 135 + 128 * throttle, radius: 0.342, width: 0.07, color: Self.throttleGradient)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: throttle)
            arc(start: 405 - 128 * brake, end: 405, radius: 0.342, width: 0.07, color: Self.red)
                .animation(reduceMotion ? nil : .linear(duration: 0.12), value: brake)

            tickLabels
            curvedLabel("THROTTLE", centerAngle: 180)
            curvedLabel("BRAKE", centerAngle: 360)
            centerReadout
        }
        .frame(width: diameter, height: diameter)
        .glassPanel(in: Circle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("telemetry-gauge")
    }

    private func arc(start: Double, end: Double, radius: CGFloat, width: CGFloat, color: some ShapeStyle) -> some View {
        Arc(start: start, end: end)
            .stroke(color, style: StrokeStyle(lineWidth: diameter * width, lineCap: .round))
            .padding(diameter * (0.5 - radius))
            .accessibilityHidden(true)
    }

    private func point(at angle: Double, radius: CGFloat) -> CGPoint {
        let rad = angle * .pi / 180
        return CGPoint(x: diameter / 2 + radius * cos(rad), y: diameter / 2 + radius * sin(rad))
    }

    private var tickLabels: some View {
        ZStack {
            ForEach(Array(stride(from: 0.0, through: unit.maximum, by: unit.tickStep)), id: \.self) { value in
                // Pull the end labels inside the ring's round caps so they never hang past the gauge edge.
                let inset = value == 0 ? 4.0 : (value >= unit.maximum ? 9.0 : 0)
                let angle = Self.scaleStart + Self.scaleSweep * value / unit.maximum + (value == 0 ? inset : -inset)
                // Tangent to the ridge, keeping the lower end labels upright.
                let tangent = (angle + 90).truncatingRemainder(dividingBy: 360)
                Text("\(Int(value))")
                    .font(.system(size: diameter * 0.044, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(value <= (speed ?? -1) ? speedInk : ink.opacity(0.85))
                    .rotationEffect(.degrees(tangent > 90 && tangent < 270 ? tangent + 180 : tangent))
                    .position(point(at: angle, radius: diameter * 0.444))
            }
        }.accessibilityHidden(true)
    }

    private func curvedLabel(_ text: String, centerAngle: Double) -> some View {
        let letters = Array(text)
        return ZStack {
            ForEach(letters.indices, id: \.self) { index in
                let angle = centerAngle + (Double(index) - Double(letters.count - 1) / 2) * 4.5
                Text(String(letters[index]))
                    .font(.system(size: diameter * 0.039, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.9))
                    .shadow(color: StintPalette.trackBlack.opacity(0.45), radius: 1)
                    .rotationEffect(.degrees(angle + 90))
                    .position(point(at: angle, radius: diameter * 0.342))
            }
        }.accessibilityHidden(true)
    }

    private var centerReadout: some View {
        VStack(spacing: diameter * 0.035) {
            Button {
                unit = unit == .kph ? .mph : .kph
            } label: {
                VStack(spacing: 0) {
                    RollingDigits(text: speed.map { "\(Int($0.rounded()))" } ?? "—", value: speed ?? 0, animated: !reduceMotion)
                        .font(.system(size: diameter * 0.18, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                    Text(unit.label)
                        .font(.system(size: diameter * 0.047, weight: .medium)).tracking(1)
                        .foregroundStyle(ink.opacity(0.6))
                }
                .frame(width: diameter * 0.49)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Speed unit")
            .accessibilityValue(speed.map { "\(Int($0.rounded())) \(unit.spokenLabel)" } ?? "Speed unavailable")
            .accessibilityHint("Switch between kilometers and miles per hour")
            .accessibilityIdentifier("telemetry-speed-unit")
            .help("Click to switch km/h and mph")

            VStack(spacing: 0) {
                RollingDigits(text: telemetry.rpm.map { $0.formatted(.number.grouping(.automatic)) } ?? "—", value: Double(telemetry.rpm ?? 0), animated: !reduceMotion)
                    .font(.system(size: diameter * 0.074, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ink)
                Text("RPM")
                    .font(.system(size: diameter * 0.043, weight: .medium)).tracking(1)
                    .foregroundStyle(ink.opacity(0.55))
            }
            .accessibilityElement(children: .combine)

            Text("DRS")
                .font(.system(size: diameter * 0.047, weight: .bold))
                .foregroundStyle(telemetry.drs ? StintPalette.trackBlack : ink.opacity(0.7))
                .padding(.horizontal, diameter * 0.04).padding(.vertical, diameter * 0.01)
                .background(telemetry.drs ? StintPalette.telemetryActive : ink.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: diameter * 0.025))
                .overlay(RoundedRectangle(cornerRadius: diameter * 0.025)
                    .strokeBorder(telemetry.drs ? StintPalette.telemetryActive : .clear, lineWidth: 1))
                .shadow(color: telemetry.drs ? StintPalette.telemetryActive.opacity(0.8) : .clear, radius: diameter * 0.035)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: telemetry.drs)
                .accessibilityLabel("DRS \(telemetry.drs ? "on" : "off")")

            HStack(alignment: .firstTextBaseline, spacing: diameter * 0.018) {
                Text("GEAR").font(.system(size: diameter * 0.047, weight: .medium)).tracking(1)
                    .foregroundStyle(ink.opacity(0.55))
                RollingDigits(text: telemetry.gear.map { "\($0)" } ?? "—", value: Double(telemetry.gear ?? 0), animated: !reduceMotion)
                    .font(.system(size: diameter * 0.088, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }
            .accessibilityElement(children: .combine)
        }
        .frame(width: diameter * 0.55)
        .fixedSize(horizontal: false, vertical: true)
        .position(x: diameter * 0.5, y: diameter * 0.575)
    }
}

private struct Arc: Shape {
    var start: Double
    var end: Double

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(start, end) }
        set { start = newValue.first; end = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard end - start > 0.001 else { return Path() }
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY),
                    radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
        return path
    }
}


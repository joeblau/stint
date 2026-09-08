import SwiftUI

/// Odometer columns keep their layout and identity while their glyphs move.
/// Only the three visible glyphs are drawn; interrupted updates retarget the current animation.
struct RollingDigits: View {
    let text: String
    let value: Double
    var animated = true

    var body: some View {
        let characters = Array(text.reversed())
        HStack(spacing: 0) {
            ForEach(characters.indices.reversed(), id: \.self) { place in
                if let digit = characters[place].wholeNumberValue {
                    RollingDigit(digit: digit, value: value, animated: animated)
                } else {
                    Text(String(characters[place]))
                }
            }
        }
        .fixedSize()
        .accessibilityRepresentation { Text(text) }
    }
}

private struct RollingDigit: View {
    let digit: Int
    let value: Double
    let animated: Bool
    @State private var phase: Double

    init(digit: Int, value: Double, animated: Bool) {
        self.digit = digit
        self.value = value
        self.animated = animated
        _phase = State(initialValue: Double(digit))
    }

    var body: some View {
        Text("8").hidden()
            .overlay {
                DigitStrip(phase: phase)
            }
            .clipped()
            .onChange(of: value) { oldValue, newValue in
                let rising = newValue >= oldValue
                let current = (Int(phase.rounded()) % 10 + 10) % 10
                let delta = rising ? (digit - current + 10) % 10 : -((current - digit + 10) % 10)
                withAnimation(animated ? .smooth(duration: 0.18, extraBounce: 0) : nil) {
                    phase += Double(delta)
                }
            }
            .onChange(of: animated) { _, enabled in
                if !enabled { withAnimation(nil) { phase = Double(digit) } }
            }
    }
}

private struct DigitStrip: View, Animatable {
    var phase: Double
    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let middle = Int(floor(phase))
            ZStack {
                ForEach((middle - 1)...(middle + 1), id: \.self) { index in
                    Text(String((index % 10 + 10) % 10))
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .position(x: geometry.size.width / 2,
                                  y: geometry.size.height * (0.5 + Double(index) - phase))
                }
            }
        }
    }
}

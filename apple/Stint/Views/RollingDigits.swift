import SwiftUI

/// Text whose characters roll vertically like an odometer when the value changes. Each character
/// slides in its own clipped slot, so digits stay crisp instead of blurring. The roll direction follows
/// the value: upward while it rises, downward while it falls.
struct RollingDigits: View {
    let text: String
    let value: Double
    var animated = true
    @State private var lastValue: Double?

    var body: some View {
        // `lastValue` still holds the previous value during the pass that introduces new digits,
        // so the transitions chosen here know which way the number moved.
        let rising = lastValue.map { value >= $0 } ?? true
        HStack(spacing: 0) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .id("\(index)-\(character)")
                    .transition(.asymmetric(
                        insertion: .move(edge: rising ? .bottom : .top).combined(with: .opacity),
                        removal: .move(edge: rising ? .top : .bottom).combined(with: .opacity)))
            }
        }
        .clipped()
        .animation(animated ? .snappy(duration: 0.22, extraBounce: 0) : nil, value: text)
        .onChange(of: value) { _, newValue in lastValue = newValue }
        .accessibilityRepresentation { Text(text) }
    }
}

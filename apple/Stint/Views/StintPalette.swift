import SwiftUI

/// Brand colors. Team liveries and telemetry status colors remain independent.
enum StintPalette {
    static let redHex = "#E10600"
    static let trackBlackHex = "#0B0B0B"
    static let asphaltHex = "#1F1F1F"
    static let pitGrayHex = "#A7A7A7"
    static let whiteHex = "#F5F5F5"

    static let red = Color(hex: redHex)
    static let trackBlack = Color(hex: trackBlackHex)
    static let asphalt = Color(hex: asphaltHex)
    static let pitGray = Color(hex: pitGrayHex)
    static let white = Color(hex: whiteHex)
    static let telemetryActive = Color(hex: "#69C98F")
}

extension Color {
    init(hex: String) { self.init(PlatformColor(hex: hex)) }
}

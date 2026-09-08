import AppKit

// Generates the Stint app icon from vector geometry. Run from the repository root:
//   swift Scripts/generate-icon.swift
//
// Outputs:
//   Stint/Resources/AppIcon.icon                     Icon Composer bundle (Liquid Glass on iOS/macOS 26+)
//   Stint/Resources/Assets.xcassets/AppIcon.appiconset  Flat PNG fallbacks for iOS 18 / macOS 15
//
// The mark is an italic "S" built from straight strokes: a red top stroke and a white
// body (middle stroke, right spine, bottom stroke). Both pieces share one italic angle.

let iconBundle = URL(fileURLWithPath: "Stint/Resources/AppIcon.icon")
let iconAssets = iconBundle.appendingPathComponent("Assets")
let appIconSet = URL(fileURLWithPath: "Stint/Resources/Assets.xcassets/AppIcon.appiconset")
for directory in [iconAssets, appIconSet] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

// MARK: - Geometry

struct Vertex {
    var point: CGPoint
    var radius: CGFloat
}

/// A closed polygon with per-vertex corner rounding, expressible as SVG path data or a CGPath.
struct RoundedPolygon {
    var vertices: [Vertex]

    func transformed(_ transform: (CGPoint) -> CGPoint, scale: CGFloat) -> RoundedPolygon {
        RoundedPolygon(vertices: vertices.map { Vertex(point: transform($0.point), radius: $0.radius * scale) })
    }

    /// Tangent points for the rounded corner at vertex `index`.
    private func tangents(at index: Int) -> (start: CGPoint, end: CGPoint, clockwise: Bool) {
        let count = vertices.count
        let previous = vertices[(index + count - 1) % count].point
        let current = vertices[index].point
        let next = vertices[(index + 1) % count].point
        let radius = vertices[index].radius
        let inbound = CGVector(dx: current.x - previous.x, dy: current.y - previous.y)
        let outbound = CGVector(dx: next.x - current.x, dy: next.y - current.y)
        let inboundLength = hypot(inbound.dx, inbound.dy)
        let outboundLength = hypot(outbound.dx, outbound.dy)
        let u1 = CGVector(dx: inbound.dx / inboundLength, dy: inbound.dy / inboundLength)
        let u2 = CGVector(dx: outbound.dx / outboundLength, dy: outbound.dy / outboundLength)
        let cosTheta = max(-1, min(1, -(u1.dx * u2.dx + u1.dy * u2.dy)))
        let theta = acos(cosTheta) // interior angle
        let distance = radius / tan(theta / 2)
        let start = CGPoint(x: current.x - u1.dx * distance, y: current.y - u1.dy * distance)
        let end = CGPoint(x: current.x + u2.dx * distance, y: current.y + u2.dy * distance)
        let cross = u1.dx * u2.dy - u1.dy * u2.dx
        return (start, end, cross > 0) // y-down space: positive cross is a clockwise turn on screen
    }

    var svgPathData: String {
        func f(_ value: CGFloat) -> String { String(format: "%.2f", value) }
        var data = ""
        for index in vertices.indices {
            let (start, end, clockwise) = tangents(at: index)
            let radius = vertices[index].radius
            data += index == 0 ? "M\(f(start.x)) \(f(start.y)) " : "L\(f(start.x)) \(f(start.y)) "
            data += "A\(f(radius)) \(f(radius)) 0 0 \(clockwise ? 1 : 0) \(f(end.x)) \(f(end.y)) "
        }
        return data + "Z"
    }

    var cgPath: CGPath {
        let path = CGMutablePath()
        for index in vertices.indices {
            let (start, _, _) = tangents(at: index)
            if index == 0 { path.move(to: start) } else { path.addLine(to: start) }
            let next = vertices[(index + 1) % vertices.count].point
            path.addArc(tangent1End: vertices[index].point, tangent2End: next, radius: vertices[index].radius)
        }
        path.closeSubpath()
        return path
    }
}

// Coordinates are in a 1024pt, y-down design space traced from the reference mark.
let slant: CGFloat = 0.65                       // horizontal run per unit of rise (≈33° italic)
func leftEdge(_ y: CGFloat) -> CGFloat { 256 + slant * (482 - y) }    // shared italic left edge
func redRight(_ y: CGFloat) -> CGFloat { 877 + slant * (438 - y) }
func bodyRight(_ y: CGFloat) -> CGFloat { 764 + slant * (650 - y) }
func spineLeft(_ y: CGFloat) -> CGFloat { 587 + slant * (644 - y) }

let topStroke = RoundedPolygon(vertices: [
    Vertex(point: CGPoint(x: leftEdge(319), y: 319), radius: 62),
    Vertex(point: CGPoint(x: redRight(319), y: 319), radius: 6),
    Vertex(point: CGPoint(x: redRight(438), y: 438), radius: 6),
    Vertex(point: CGPoint(x: leftEdge(438), y: 438), radius: 6),
])

let body = RoundedPolygon(vertices: [
    Vertex(point: CGPoint(x: leftEdge(482), y: 482), radius: 24),      // middle stroke, top-left
    Vertex(point: CGPoint(x: bodyRight(482), y: 482), radius: 44),     // middle stroke, top-right (acute)
    Vertex(point: CGPoint(x: bodyRight(766), y: 766), radius: 62),     // bottom stroke, bottom-right
    Vertex(point: CGPoint(x: leftEdge(766), y: 766), radius: 6),       // bottom stroke, bottom-left
    Vertex(point: CGPoint(x: leftEdge(650), y: 650), radius: 6),       // bottom stroke, top-left
    Vertex(point: CGPoint(x: spineLeft(650), y: 650), radius: 14),     // counter, inner bottom
    Vertex(point: CGPoint(x: spineLeft(598), y: 598), radius: 14),     // counter, inner top
    Vertex(point: CGPoint(x: leftEdge(598), y: 598), radius: 6),       // middle stroke, bottom-left
])

// Center the mark on the canvas and scale it so it sits inside the icon's safe area.
let markScale: CGFloat = 0.84
let markCenter = CGPoint(x: (leftEdge(766) + redRight(319)) / 2, y: (319 + 766) / 2)
func place(_ point: CGPoint) -> CGPoint {
    CGPoint(x: (point.x - markCenter.x) * markScale + 512, y: (point.y - markCenter.y) * markScale + 512)
}
let placedTop = topStroke.transformed(place, scale: markScale)
let placedBody = body.transformed(place, scale: markScale)

// MARK: - Colors

let red = (r: 0.882, g: 0.024, b: 0.0) // Stint Red #E10600
let white = (r: 0.96, g: 0.96, b: 0.96)
let backgroundTop = (r: 0.11, g: 0.11, b: 0.12)
let backgroundBottom = (r: 0.03, g: 0.03, b: 0.03)
func hex(_ c: (r: Double, g: Double, b: Double)) -> String {
    String(format: "#%02X%02X%02X", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
}

// MARK: - Icon Composer bundle (Liquid Glass)

func svg(_ polygon: RoundedPolygon, fill: String) -> String {
    """
    <svg width="1024" height="1024" viewBox="0 0 1024 1024" xmlns="http://www.w3.org/2000/svg">
    <path d="\(polygon.svgPathData)" fill="\(fill)"/>
    </svg>

    """
}
try svg(placedTop, fill: hex(red)).write(to: iconAssets.appendingPathComponent("s-top.svg"), atomically: true, encoding: .utf8)
try svg(placedBody, fill: hex(white)).write(to: iconAssets.appendingPathComponent("s-body.svg"), atomically: true, encoding: .utf8)

// Note: actool (Xcode 27 beta 6) rejects `"shadow": {"kind": "chromatic"}` with "Icon export exited with status 255"; keep shadows neutral.
let iconDescription: [String: Any] = [
    "fill": ["automatic-gradient": "extended-srgb:0.08000,0.08000,0.09000,1.00000"],
    "groups": [
        [
            "layers": [["fill": "none", "glass": true, "image-name": "s-top.svg", "name": "S Top", "opacity": 1]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.5],
        ],
        [
            "layers": [["fill": "none", "glass": true, "image-name": "s-body.svg", "name": "S Body", "opacity": 1]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.5],
        ],
    ],
    "supported-platforms": ["circles": ["watchOS"], "squares": "shared"],
]
try JSONSerialization.data(withJSONObject: iconDescription, options: [.prettyPrinted, .sortedKeys])
    .write(to: iconBundle.appendingPathComponent("icon.json"))

// MARK: - Flat PNG fallbacks (iOS 18 / macOS 15)

/// Renders the mark at `pixels`. macOS icons are pre-shaped rounded squares; iOS icons are full-bleed.
func render(pixels: Int, filename: String, macShape: Bool) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let context = NSGraphicsContext.current!.cgContext
    // Flip to the y-down design space and scale to the output size.
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    context.setShouldAntialias(true)

    // Background tile: macOS icons occupy the central 824pt with 185pt corners; iOS is full-bleed.
    let tile = macShape ? CGRect(x: 100, y: 100, width: 824, height: 824) : CGRect(x: 0, y: 0, width: 1024, height: 1024)
    let tilePath = macShape ? CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil) : CGPath(rect: tile, transform: nil)
    context.saveGState()
    context.addPath(tilePath)
    context.clip()
    let colors = [
        CGColor(red: backgroundTop.r, green: backgroundTop.g, blue: backgroundTop.b, alpha: 1),
        CGColor(red: backgroundBottom.r, green: backgroundBottom.g, blue: backgroundBottom.b, alpha: 1),
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY), options: [])
    context.restoreGState()

    // The mark, scaled with the tile so it keeps the same proportion inside the shape.
    context.saveGState()
    context.translateBy(x: tile.midX, y: tile.midY)
    context.scaleBy(x: tile.width / 1024, y: tile.height / 1024)
    context.translateBy(x: -512, y: -512)
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: CGColor(gray: 0, alpha: 0.5))
    context.setFillColor(red: white.r, green: white.g, blue: white.b, alpha: 1)
    context.addPath(placedBody.cgPath)
    context.fillPath()
    context.setFillColor(red: red.r, green: red.g, blue: red.b, alpha: 1)
    context.addPath(placedTop.cgPath)
    context.fillPath()
    context.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: appIconSet.appendingPathComponent(filename))
}

var entries: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let file = "mac-\(size)@\(scale)x.png"
        try render(pixels: size * scale, filename: file, macShape: true)
        entries.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": file])
    }
}
try render(pixels: 1024, filename: "ipad-1024.png", macShape: false)
entries.append(["idiom": "universal", "platform": "ios", "size": "1024x1024", "filename": "ipad-1024.png"])
let contents: [String: Any] = ["images": entries, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: appIconSet.appendingPathComponent("Contents.json"))
print("Wrote \(iconBundle.path) and \(appIconSet.path)")

#!/usr/bin/env swift
// Renders every app-icon and top-shelf asset from code so the artwork is
// regenerable: `swift scripts/generate-artwork.swift` from the repo root.
// Writes PNGs plus the Contents.json manifests that reference them.

import AppKit

// MARK: - Palette

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let bgOuter = rgb(0x05_09_1C)
let bgInner = rgb(0x0E_1A_42)
let well = rgb(0x0A_14_33)
let cyan = rgb(0x5F_EC_E6)
let cyanMid = rgb(0x35_C9_EE)
let waveCyan = rgb(0x3E_B6_E8)
let blue = rgb(0x2E_6B_EA)
let blueMid = rgb(0x34_57_E4)
let violet = rgb(0x76_5A_E8)
let violetLight = rgb(0x8A_6D_F2)
let mint = rgb(0xC8_F6_EE)

func gradient(_ colors: [NSColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors.map(\.cgColor) as CFArray,
        locations: locations
    )!
}

// MARK: - Rendering plumbing

func renderPNG(width: Int, height: Int, opaque: Bool, draw: (CGContext, CGSize) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let size = CGSize(width: width, height: height)
    if opaque {
        cg.setFillColor(bgOuter.cgColor)
        cg.fill(CGRect(origin: .zero, size: size))
    }
    draw(cg, size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func write(_ data: Data, _ path: String) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true
    )
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func writeJSON(_ object: [String: Any], _ path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    write(data, path)
}

// MARK: - Drawing pieces

func drawBackground(_ cg: CGContext, _ size: CGSize, glow: Bool) {
    cg.setFillColor(bgOuter.cgColor)
    cg.fill(CGRect(origin: .zero, size: size))
    cg.drawRadialGradient(
        gradient([bgInner, bgOuter], [0, 1]),
        startCenter: CGPoint(x: size.width / 2, y: size.height * 0.56), startRadius: 0,
        endCenter: CGPoint(x: size.width / 2, y: size.height * 0.5),
        endRadius: min(size.width, size.height) * 0.78,
        options: [.drawsAfterEndLocation]
    )
}

/// The mark is three depths, which is also how it splits across the tvOS
/// parallax layers: the disc sits still, the water moves over it, and the play
/// mark floats in front.
enum MarkPart { case disc, water, play }

func markGeometry(_ size: CGSize) -> (centre: CGPoint, outer: CGFloat, inner: CGFloat, unit: CGFloat) {
    let unit = min(size.width, size.height)
    return (
        CGPoint(x: size.width / 2, y: size.height / 2),
        unit * 0.385,
        unit * 0.385 * 0.700,
        unit
    )
}

/// A crest line filled to the bottom of the frame.
func wavePath(_ size: CGSize, baseline: CGFloat, amplitude: CGFloat, phase: CGFloat, tilt: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let y = size.height * baseline
    let a = size.height * amplitude
    path.move(to: CGPoint(x: -size.width * 0.1, y: y + sin(phase) * a))
    path.addCurve(
        to: CGPoint(x: size.width * 0.46, y: y + cos(phase) * a * 0.8 + size.height * tilt),
        control1: CGPoint(x: size.width * 0.10, y: y + cos(phase) * a * 2.0),
        control2: CGPoint(x: size.width * 0.30, y: y - sin(phase) * a * 1.7)
    )
    path.addCurve(
        to: CGPoint(x: size.width * 1.1, y: y - sin(phase) * a * 1.4 + size.height * tilt * 1.8),
        control1: CGPoint(x: size.width * 0.64, y: y + sin(phase) * a * 1.9 + size.height * tilt),
        control2: CGPoint(x: size.width * 0.88, y: y - cos(phase) * a * 1.2 + size.height * tilt * 2)
    )
    path.addLine(to: CGPoint(x: size.width * 1.1, y: -size.height * 0.1))
    path.addLine(to: CGPoint(x: -size.width * 0.1, y: -size.height * 0.1))
    path.closeSubpath()
    return path
}

func roundedTriangle(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: (points[0].x + points[1].x) / 2, y: (points[0].y + points[1].y) / 2))
    for index in 1...3 {
        path.addArc(tangent1End: points[index % 3], tangent2End: points[(index + 1) % 3], radius: radius)
    }
    path.closeSubpath()
    return path
}

func drawMark(_ cg: CGContext, _ size: CGSize, parts: Set<MarkPart>) {
    let (c, outer, inner, u) = markGeometry(size)

    if parts.contains(.disc) {
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: u * 0.070, color: cyanMid.withAlphaComponent(0.45).cgColor)
        cg.setFillColor(cyanMid.withAlphaComponent(0.9).cgColor)
        cg.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        cg.restoreGState()

        cg.saveGState()
        let ring = CGMutablePath()
        ring.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        ring.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        cg.addPath(ring)
        cg.clip(using: .evenOdd)
        cg.drawLinearGradient(
            gradient([cyan, cyanMid, blue, violet], [0, 0.34, 0.66, 1]),
            start: CGPoint(x: c.x - outer * 0.5, y: c.y + outer),
            end: CGPoint(x: c.x + outer, y: c.y - outer),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        cg.restoreGState()

        cg.saveGState()
        cg.addEllipse(in: CGRect(x: c.x - inner, y: c.y - inner, width: inner * 2, height: inner * 2))
        cg.clip()
        cg.drawRadialGradient(
            gradient([rgb(0x10_1E_48), well], [0, 1]),
            startCenter: CGPoint(x: c.x, y: c.y + inner * 0.3), startRadius: 0,
            endCenter: c, endRadius: inner * 1.4, options: [.drawsAfterEndLocation]
        )
        cg.restoreGState()
    }

    if parts.contains(.water) {
        cg.saveGState()
        cg.addEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
        cg.clip()
        let bands: [(CGFloat, CGFloat, CGFloat, CGFloat, [NSColor], CGFloat)] = [
            (0.415, 0.026, 0.5, -0.015, [waveCyan, blue], 0.68),
            (0.345, 0.032, 2.1, 0.010, [blue, blueMid], 0.80),
            (0.275, 0.028, 3.6, 0.028, [rgb(0x4B_5A_EA), violet], 0.90),
            (0.200, 0.022, 5.0, 0.018, [violet, violetLight], 0.92),
        ]
        for (baseline, amplitude, phase, tilt, colors, alpha) in bands {
            cg.saveGState()
            cg.addPath(wavePath(size, baseline: baseline, amplitude: amplitude, phase: phase, tilt: tilt))
            cg.clip()
            cg.setAlpha(alpha)
            cg.drawLinearGradient(
                gradient(colors, [0, 1]),
                start: CGPoint(x: c.x - outer, y: c.y),
                end: CGPoint(x: c.x + outer, y: c.y - outer),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
            cg.restoreGState()
        }
        cg.restoreGState()
    }

    if parts.contains(.play) {
        let t = u * 0.100
        let tc = CGPoint(x: c.x - u * 0.004, y: c.y + u * 0.028)
        let triangle = roundedTriangle([
            CGPoint(x: tc.x - t * 0.80, y: tc.y + t * 1.05),
            CGPoint(x: tc.x - t * 0.80, y: tc.y - t * 1.05),
            CGPoint(x: tc.x + t * 1.02, y: tc.y),
        ], radius: u * 0.018)
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: u * 0.032, color: cyanMid.withAlphaComponent(0.75).cgColor)
        cg.setFillColor(NSColor.white.cgColor)
        cg.addPath(triangle)
        cg.fillPath()
        cg.restoreGState()
        cg.saveGState()
        cg.addPath(triangle)
        cg.clip()
        cg.drawLinearGradient(
            gradient([rgb(0x7A_F0_E4), rgb(0x3D_A8_F2)], [0, 1]),
            start: CGPoint(x: tc.x - t, y: tc.y + t), end: CGPoint(x: tc.x + t, y: tc.y - t), options: []
        )
        cg.restoreGState()
    }
}

/// A jellyfish reduced to a bell and four filaments, in the mark's palette.
/// It lives on the Top Shelf, which is wide enough for it to read as a
/// creature rather than a speck.
func drawJellyfish(_ cg: CGContext, at center: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    let bell = CGMutablePath()
    bell.move(to: CGPoint(x: center.x - r, y: center.y))
    bell.addArc(center: center, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    bell.addQuadCurve(
        to: CGPoint(x: center.x - r, y: center.y),
        control: CGPoint(x: center.x, y: center.y - r * 0.40)
    )
    cg.setFillColor(violetLight.withAlphaComponent(alpha).cgColor)
    cg.addPath(bell)
    cg.fillPath()

    cg.setLineCap(.round)
    cg.setLineWidth(r * 0.13)
    for (index, offset) in [-0.56, -0.19, 0.19, 0.56].enumerated() {
        let x = center.x + r * CGFloat(offset)
        let sway: CGFloat = index % 2 == 0 ? 1 : -1
        let tentacle = CGMutablePath()
        tentacle.move(to: CGPoint(x: x, y: center.y - r * 0.18))
        tentacle.addQuadCurve(
            to: CGPoint(x: x + r * 0.28 * sway, y: center.y - r * 1.30),
            control: CGPoint(x: x - r * 0.26 * sway, y: center.y - r * 0.78)
        )
        cg.setStrokeColor(cyanMid.withAlphaComponent(alpha * 0.7).cgColor)
        cg.addPath(tentacle)
        cg.strokePath()
    }
}

func wordmarkAttributes(_ fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: cyan,
    ]
}

func wordmarkSize(_ fontSize: CGFloat) -> CGSize {
    NSAttributedString(string: "Lagoon", attributes: wordmarkAttributes(fontSize)).size()
}

func drawWordmark(_ cg: CGContext, fontSize: CGFloat, leading: CGPoint) {
    let text = NSAttributedString(string: "Lagoon", attributes: wordmarkAttributes(fontSize))
    text.draw(at: CGPoint(x: leading.x, y: leading.y - text.size().height / 2))
}

// MARK: - Asset compositions

func backLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawMark(cg, size, parts: [.disc])
    }
}

func middleLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        drawMark(cg, size, parts: [.water])
    }
}

func frontLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        drawMark(cg, size, parts: [.play])
    }
}

func flatIcon(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawMark(cg, size, parts: [.disc, .water, .play])
    }
}

/// The wide banner: the mark and wordmark as one measured lockup, with
/// jellyfish drifting at three depths.
func topShelf(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)

        let markSize = size.height * 0.78
        let fontSize = size.height * 0.30
        let gap = size.height * 0.05
        // Measured, not guessed: centring the two independently overlapped
        // them into "LLagoon" the first time.
        let text = wordmarkSize(fontSize)
        let lockup = markSize + gap + text.width
        let originX = size.width * 0.5 - lockup / 2

        for drifter in [
            (x: 0.115, y: 0.62, r: 0.070, alpha: 0.75),
            (x: 0.885, y: 0.70, r: 0.052, alpha: 0.55),
            (x: 0.805, y: 0.26, r: 0.034, alpha: 0.35),
        ] {
            drawJellyfish(
                cg,
                at: CGPoint(x: size.width * drifter.x, y: size.height * drifter.y),
                radius: size.height * drifter.r,
                alpha: drifter.alpha
            )
        }

        cg.saveGState()
        cg.translateBy(x: originX, y: size.height * 0.5 - markSize / 2)
        drawMark(cg, CGSize(width: markSize, height: markSize), parts: [.disc, .water, .play])
        cg.restoreGState()

        drawWordmark(
            cg,
            fontSize: fontSize,
            leading: CGPoint(x: originX + markSize + gap, y: size.height * 0.5)
        )
    }
}

// MARK: - Emit everything

let catalog = "Lagoon/Assets.xcassets"
let brand = "\(catalog)/App Icon & Top Shelf Image.brandassets"

func emitLayered(stack: String, w: Int, h: Int) {
    let layers: [(String, (Int, Int) -> Data)] = [
        ("Back", backLayer), ("Middle", middleLayer), ("Front", frontLayer),
    ]
    for (name, generate) in layers {
        let imageset = "\(brand)/\(stack).imagestack/\(name).imagestacklayer/Content.imageset"
        write(generate(w, h), "\(imageset)/\(name.lowercased()).png")
        write(generate(w * 2, h * 2), "\(imageset)/\(name.lowercased())@2x.png")
        writeJSON([
            "images": [
                ["filename": "\(name.lowercased()).png", "idiom": "tv", "scale": "1x"],
                ["filename": "\(name.lowercased())@2x.png", "idiom": "tv", "scale": "2x"],
            ],
            "info": ["author": "generate-artwork", "version": 1],
        ], "\(imageset)/Contents.json")
    }
}

emitLayered(stack: "App Icon", w: 400, h: 240)
emitLayered(stack: "App Icon - App Store", w: 1280, h: 768)

for (name, w, h) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    let imageset = "\(brand)/\(name).imageset"
    let file = name.lowercased().replacingOccurrences(of: " ", with: "-")
    write(topShelf(w, h), "\(imageset)/\(file).png")
    write(topShelf(w * 2, h * 2), "\(imageset)/\(file)@2x.png")
    writeJSON([
        "images": [
            ["filename": "\(file).png", "idiom": "tv", "scale": "1x"],
            ["filename": "\(file)@2x.png", "idiom": "tv", "scale": "2x"],
        ],
        "info": ["author": "generate-artwork", "version": 1],
    ], "\(imageset)/Contents.json")
}

write(flatIcon(1024, 1024), "\(catalog)/AppIcon.appiconset/appicon.png")
writeJSON([
    "images": [
        ["filename": "appicon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
    ],
    "info": ["author": "generate-artwork", "version": 1],
], "\(catalog)/AppIcon.appiconset/Contents.json")

print("done")

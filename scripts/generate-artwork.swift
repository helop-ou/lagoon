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

let deepTop = rgb(0x06_1A_28)
let deepBottom = rgb(0x08_2E_44)
let teal = rgb(0x4A_D1_C7)
let tealMid = rgb(0x2F_AE_A9)
let mint = rgb(0xC8_F6_EE)
let oceanDeep = rgb(0x06_35_4D)
let oceanMid = rgb(0x0B_67_73)
let sand = rgb(0xF1_DF_B5)
let jellyViolet = rgb(0x8C_82_DF)

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
        cg.setFillColor(deepBottom.cgColor)
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
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [oceanMid.cgColor, oceanDeep.cgColor, deepTop.cgColor] as CFArray,
        locations: [0, 0.62, 1]
    )!
    cg.drawLinearGradient(
        gradient,
        start: CGPoint(x: size.width * 0.12, y: 0),
        end: CGPoint(x: size.width * 0.88, y: size.height),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    if glow {
        let glowGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [teal.withAlphaComponent(0.24).cgColor, teal.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        cg.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: size.width * 0.43, y: size.height * 0.38), startRadius: 0,
            endCenter: CGPoint(x: size.width * 0.43, y: size.height * 0.38), endRadius: max(size.width, size.height) * 0.62,
            options: []
        )

        let coolGlow = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [tealMid.withAlphaComponent(0.12).cgColor, tealMid.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        cg.drawRadialGradient(
            coolGlow,
            startCenter: CGPoint(x: size.width * 0.74, y: size.height * 0.82), startRadius: 0,
            endCenter: CGPoint(x: size.width * 0.74, y: size.height * 0.82), endRadius: max(size.width, size.height) * 0.46,
            options: []
        )
    }
}

/// A quiet tidal contour. The curves give the flat icon some depth and become
/// the middle parallax layer on tvOS without competing with the logo mark.
func tidePath(_ size: CGSize, baseline: CGFloat, phase: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let y = size.height * baseline
    let amplitude = size.height * 0.055
    path.move(to: CGPoint(x: -size.width * 0.08, y: y + sin(phase) * amplitude))
    path.addCurve(
        to: CGPoint(x: size.width * 0.52, y: y + cos(phase) * amplitude),
        control1: CGPoint(x: size.width * 0.10, y: y + cos(phase) * amplitude * 1.8),
        control2: CGPoint(x: size.width * 0.34, y: y - sin(phase) * amplitude * 1.6)
    )
    path.addCurve(
        to: CGPoint(x: size.width * 1.08, y: y - sin(phase) * amplitude),
        control1: CGPoint(x: size.width * 0.70, y: y + sin(phase) * amplitude * 1.7),
        control2: CGPoint(x: size.width * 0.90, y: y - cos(phase) * amplitude * 1.5)
    )
    return path
}

func drawWaves(_ cg: CGContext, _ size: CGSize) {
    let contours: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (0.16, 0.35, 0.012, teal.withAlphaComponent(0.22)),
        (0.25, 1.25, 0.009, tealMid.withAlphaComponent(0.18)),
        (0.34, 2.10, 0.007, mint.withAlphaComponent(0.10)),
    ]
    cg.setLineCap(.round)
    for contour in contours {
        cg.setStrokeColor(contour.3.cgColor)
        cg.setLineWidth(size.height * contour.2)
        cg.addPath(tidePath(size, baseline: contour.0, phase: contour.1))
        cg.strokePath()
    }
}

/// The letterform as a lagoon read off a chart: concentric depth bands
/// following one L-shaped spine, deep water at the outside stepping in to the
/// bright shallows at its core. The letter *is* the water — nothing is placed
/// beside anything, which is what made the previous icon read as a sticker
/// album rather than a mark.
func lSpine(_ size: CGSize) -> CGPath {
    let unit = min(size.width, size.height)
    let c = CGPoint(x: size.width / 2, y: size.height / 2)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: c.x - unit * 0.150, y: c.y + unit * 0.285))
    path.addLine(to: CGPoint(x: c.x - unit * 0.150, y: c.y - unit * 0.195))
    path.addLine(to: CGPoint(x: c.x + unit * 0.215, y: c.y - unit * 0.195))
    return path
}

/// Outermost (deepest) first. Split across the tvOS parallax layers so the
/// bright core lifts away from the deep water on focus: at rest a flat mark,
/// in motion a lagoon you are looking into.
let depthBands: [(width: CGFloat, color: NSColor)] = [
    (0.300, oceanDeep.withAlphaComponent(0.55)),
    (0.242, oceanMid),
    (0.180, tealMid),
    (0.120, teal),
    (0.059, mint),
]

func drawContours(_ cg: CGContext, _ size: CGSize, _ bands: ArraySlice<(width: CGFloat, color: NSColor)>) {
    let unit = min(size.width, size.height)
    let path = lSpine(size)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    for band in bands {
        cg.setStrokeColor(band.color.cgColor)
        cg.setLineWidth(unit * band.width)
        cg.addPath(path)
        cg.strokePath()
    }
}

/// A jellyfish reduced to a bell and four filaments. It lives on the Top Shelf
/// artwork, which is wide enough to hold it: at icon size it could only ever
/// sit next to the letter rather than belong to it.
func drawJellyfish(_ cg: CGContext, at center: CGPoint, radius r: CGFloat, alpha: CGFloat) {
    let bell = CGMutablePath()
    bell.move(to: CGPoint(x: center.x - r, y: center.y))
    bell.addArc(center: center, radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
    bell.addQuadCurve(
        to: CGPoint(x: center.x - r, y: center.y),
        control: CGPoint(x: center.x, y: center.y - r * 0.40)
    )
    cg.setFillColor(jellyViolet.withAlphaComponent(alpha).cgColor)
    cg.addPath(bell)
    cg.fillPath()
    cg.setStrokeColor(mint.withAlphaComponent(alpha * 0.75).cgColor)
    cg.setLineWidth(r * 0.11)
    cg.addPath(bell)
    cg.strokePath()

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
        cg.setStrokeColor(mint.withAlphaComponent(alpha * 0.62).cgColor)
        cg.addPath(tentacle)
        cg.strokePath()
    }
}

func wordmarkAttributes(_ fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
    [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: mint,
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
        // The two deepest bands belong to the water and stay put.
        drawContours(cg, size, depthBands[0..<2])
    }
}

func middleLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        drawContours(cg, size, depthBands[2..<4])
    }
}

func frontLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        // Only the bright core, so focus lifts it clear of the deep.
        drawContours(cg, size, depthBands[4...])
    }
}

func flatIcon(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawContours(cg, size, depthBands[...])
    }
}

/// The wide banner is where the Jellyfin lineage gets room: the mark and
/// wordmark as one measured lockup, with jellyfish drifting at three depths.
/// The banner is the only place they can be large enough to read as creatures
/// rather than as specks.
func topShelf(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawWaves(cg, size)

        let markSize = size.height * 0.58
        let fontSize = size.height * 0.30
        let gap = size.height * 0.06
        // Measured rather than guessed: the first attempt centred the two
        // pieces independently and they overlapped into "LLagoon".
        let text = wordmarkSize(fontSize)
        let lockup = markSize + gap + text.width
        let originX = size.width * 0.5 - lockup / 2

        let drifters: [(x: CGFloat, y: CGFloat, r: CGFloat, alpha: CGFloat)] = [
            (0.115, 0.62, 0.070, 0.90),
            (0.885, 0.70, 0.052, 0.66),
            (0.805, 0.28, 0.034, 0.42),
        ]
        for drifter in drifters {
            drawJellyfish(
                cg,
                at: CGPoint(x: size.width * drifter.x, y: size.height * drifter.y),
                radius: size.height * drifter.r,
                alpha: drifter.alpha
            )
        }

        cg.saveGState()
        cg.translateBy(x: originX, y: size.height * 0.5 - markSize / 2)
        drawContours(cg, CGSize(width: markSize, height: markSize), depthBands[...])
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

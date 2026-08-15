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
let tealDark = rgb(0x1E_6E_78)
let tealMid = rgb(0x2F_9E_9B)

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
        colors: [deepBottom.cgColor, deepTop.cgColor] as CFArray,
        locations: [0, 1]
    )!
    cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
    if glow {
        let glowGradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [teal.withAlphaComponent(0.32).cgColor, teal.withAlphaComponent(0).cgColor] as CFArray,
            locations: [0, 1]
        )!
        cg.drawRadialGradient(
            glowGradient,
            startCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.30), startRadius: 0,
            endCenter: CGPoint(x: size.width * 0.5, y: size.height * 0.30), endRadius: size.width * 0.55,
            options: []
        )
    }
}

/// One water band: a gentle two-crest curve filled down to the bottom edge.
func wavePath(_ size: CGSize, baseline: CGFloat, amplitude: CGFloat, phase: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let y = size.height * baseline
    let amp = size.height * amplitude
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: y + amp * sin(phase)))
    let steps = 48
    for i in 1...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let x = size.width * t
        path.addLine(to: CGPoint(x: x, y: y + amp * sin(phase + t * .pi * 2.2)))
    }
    path.addLine(to: CGPoint(x: size.width, y: 0))
    path.closeSubpath()
    return path
}

func drawWaves(_ cg: CGContext, _ size: CGSize) {
    let bands: [(CGFloat, CGFloat, NSColor)] = [
        (0.34, 0.030, tealDark.withAlphaComponent(0.55)),
        (0.26, 0.026, tealMid.withAlphaComponent(0.65)),
        (0.18, 0.022, teal.withAlphaComponent(0.85)),
    ]
    for (index, band) in bands.enumerated() {
        cg.setFillColor(band.2.cgColor)
        cg.addPath(wavePath(size, baseline: band.0, amplitude: band.1, phase: CGFloat(index) * 1.9 + 0.6))
        cg.fillPath()
    }
}

/// Rounded play triangle, corners via thick round-join stroke over the fill.
func drawPlayMark(_ cg: CGContext, _ size: CGSize, center: CGPoint, height: CGFloat) {
    let h = height
    let corner = h * 0.16
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - h * 0.34, y: center.y + h * 0.5))
    path.addLine(to: CGPoint(x: center.x - h * 0.34, y: center.y - h * 0.5))
    path.addLine(to: CGPoint(x: center.x + h * 0.52, y: center.y))
    path.closeSubpath()
    cg.setFillColor(NSColor.white.cgColor)
    cg.setStrokeColor(NSColor.white.cgColor)
    cg.setLineWidth(corner)
    cg.setLineJoin(.round)
    // Two passes: the shadow caster first, then a clean fill+stroke on top —
    // one pass leaves the stroke's shadow smeared across the fill interior.
    cg.setShadow(offset: CGSize(width: 0, height: -h * 0.05), blur: h * 0.22, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    cg.addPath(path)
    cg.drawPath(using: .stroke)
    cg.setShadow(offset: .zero, blur: 0, color: nil)
    cg.addPath(path)
    cg.drawPath(using: .fillStroke)
}

func drawWordmark(_ cg: CGContext, _ size: CGSize, fontSize: CGFloat, center: CGPoint) {
    let text = NSAttributedString(
        string: "Lagoon",
        attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: teal,
        ]
    )
    let bounds = text.size()
    text.draw(at: CGPoint(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2))
}

// MARK: - Asset compositions

func backLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
    }
}

func middleLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        drawWaves(cg, size)
    }
}

func frontLayer(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: false) { cg, size in
        drawPlayMark(cg, size, center: CGPoint(x: size.width * 0.5, y: size.height * 0.56), height: size.height * 0.34)
    }
}

func flatIcon(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawWaves(cg, size)
        drawPlayMark(cg, size, center: CGPoint(x: size.width * 0.5, y: size.height * 0.56), height: size.height * 0.30)
    }
}

func topShelf(_ w: Int, _ h: Int) -> Data {
    renderPNG(width: w, height: h, opaque: true) { cg, size in
        drawBackground(cg, size, glow: true)
        drawWaves(cg, size)
        drawWordmark(cg, size, fontSize: size.height * 0.30, center: CGPoint(x: size.width * 0.5, y: size.height * 0.60))
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

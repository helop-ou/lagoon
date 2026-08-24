#!/usr/bin/env swift
// Turns supplied artwork into every asset the catalogue needs, so the design
// can come from wherever it comes from and the production is mechanical.
//
//   scripts/import-artwork.swift --icon art/icon.png
//   scripts/import-artwork.swift --icon art/icon.png --topshelf art/banner.png
//   scripts/import-artwork.swift --back art/back.png --middle art/mid.png \
//                                --front art/front.png --icon art/icon.png
//
// --icon      square source. Becomes the iOS icon, and is composed onto the
//             5:3 tvOS frame (tvOS icons are *not* square).
// --back/--middle/--front
//             optional per-layer art for the tvOS parallax stack. Supply
//             these to control the depth effect; without them the icon is
//             placed on the Back layer and the stack is flat but valid.
// --topshelf  optional wide banner. Without it the banner is composed from
//             the palette background and the icon.
//
// Everything is aspect-filled and centred, never squashed.

import AppKit

// MARK: - Palette (matches generate-artwork.swift)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF)/255, green: CGFloat((hex >> 8) & 0xFF)/255,
            blue: CGFloat(hex & 0xFF)/255, alpha: 1)
}
let deepTop = rgb(0x06_1A_28), oceanDeep = rgb(0x06_35_4D), oceanMid = rgb(0x0B_67_73)

// MARK: - Arguments

var options: [String: String] = [:]
var arguments = Array(CommandLine.arguments.dropFirst())
while let flag = arguments.first {
    guard flag.hasPrefix("--"), arguments.count >= 2 else {
        FileHandle.standardError.write(Data("error: unexpected argument \(flag)\n".utf8))
        exit(1)
    }
    options[String(flag.dropFirst(2))] = arguments[1]
    arguments.removeFirst(2)
}

func source(_ key: String) -> NSImage? {
    guard let path = options[key] else { return nil }
    guard let image = NSImage(contentsOfFile: path) else {
        FileHandle.standardError.write(Data("error: could not read \(path)\n".utf8))
        exit(1)
    }
    return image
}

guard let icon = source("icon") ?? source("back") else {
    print("""
    usage: import-artwork.swift --icon <square.png> [--topshelf <wide.png>]
                                [--back <p> --middle <p> --front <p>]

    Nothing was supplied, so nothing was written.
    """)
    exit(1)
}

/// The supplied artwork's edge colour, used to extend it into frames of a
/// different aspect ratio.
let frameColor: NSColor = {
    guard let icon = source("icon") ?? source("back"),
          let tiff = icon.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          // The corner, not the mid-edge: mid-edge lands inside the
          // artwork's own field, which framed a dark icon in bright blue.
          let corner = rep.colorAt(x: 2, y: 2) else {
        return rgb(0x06_1A_28)
    }
    return corner.usingColorSpace(.deviceRGB) ?? rgb(0x06_1A_28)
}()

// MARK: - Drawing

func render(width: Int, height: Int, opaque: Bool, _ draw: (CGSize) -> Void) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let size = CGSize(width: width, height: height)
    if opaque {
        // Sampled from the artwork's own corner rather than assumed, so the
        // 5:3 tvOS frame extends the supplied art instead of framing it in a
        // palette that may have nothing to do with it.
        context.cgContext.setFillColor(frameColor.cgColor)
        context.cgContext.fill(CGRect(origin: .zero, size: size))
    }
    draw(size)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Aspect-fill: cover the frame, crop the overflow, never distort.
func fill(_ image: NSImage, _ frame: CGSize) {
    let source = image.size
    let scale = max(frame.width / source.width, frame.height / source.height)
    let drawn = CGSize(width: source.width * scale, height: source.height * scale)
    image.draw(
        in: CGRect(x: (frame.width - drawn.width)/2, y: (frame.height - drawn.height)/2,
                   width: drawn.width, height: drawn.height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

/// Aspect-fit: show all of it, centred, leaving the frame's own background
/// visible. Used for the 5:3 tvOS frame so a square icon is not cropped.
func fit(_ image: NSImage, _ frame: CGSize, inset: CGFloat = 1.0) {
    let source = image.size
    let scale = min(frame.width / source.width, frame.height / source.height) * inset
    let drawn = CGSize(width: source.width * scale, height: source.height * scale)
    image.draw(
        in: CGRect(x: (frame.width - drawn.width)/2, y: (frame.height - drawn.height)/2,
                   width: drawn.width, height: drawn.height),
        from: .zero, operation: .sourceOver, fraction: 1
    )
}

func write(_ data: Data, _ path: String) {
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
    )
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

func writeJSON(_ object: [String: Any], _ path: String) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    write(data, path)
}

// MARK: - Emit

let catalog = "Lagoon/Assets.xcassets"
let brand = "\(catalog)/App Icon & Top Shelf Image.brandassets"

// iOS: one square, opaque (the system applies its own mask).
write(render(width: 1024, height: 1024, opaque: true) { fill(icon, $0) },
      "\(catalog)/AppIcon.appiconset/appicon.png")
writeJSON([
    "images": [["filename": "appicon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"]],
    "info": ["author": "import-artwork", "version": 1],
], "\(catalog)/AppIcon.appiconset/Contents.json")

// tvOS: layered stacks at 5:3. Only Back is opaque; the others must carry
// alpha or they would hide everything beneath them.
let layerArt: [(name: String, image: NSImage?, opaque: Bool)] = [
    ("Back", source("back") ?? icon, true),
    ("Middle", source("middle"), false),
    ("Front", source("front"), false),
]

func emitStack(_ stack: String, _ w: Int, _ h: Int) {
    for layer in layerArt {
        let imageset = "\(brand)/\(stack).imagestack/\(layer.name).imagestacklayer/Content.imageset"
        let file = layer.name.lowercased()
        for (suffix, scale) in [("", 1), ("@2x", 2)] {
            let data = render(width: w * scale, height: h * scale, opaque: layer.opaque) { size in
                guard let image = layer.image else { return }
                // The Back layer fills its frame; the parallax layers sit on
                // top and are fitted so nothing is cropped away.
                fit(image, size)
            }
            write(data, "\(imageset)/\(file)\(suffix).png")
        }
        writeJSON([
            "images": [
                ["filename": "\(file).png", "idiom": "tv", "scale": "1x"],
                ["filename": "\(file)@2x.png", "idiom": "tv", "scale": "2x"],
            ],
            "info": ["author": "import-artwork", "version": 1],
        ], "\(imageset)/Contents.json")
    }
}

emitStack("App Icon", 400, 240)
emitStack("App Icon - App Store", 1280, 768)

/// Without a supplied banner, compose one: the mark lifted out of the icon —
/// clipped to a circle so the icon's own rounded-square edge does not read as
/// a card floating on the background — beside the wordmark.
func drawLockup(_ image: NSImage, _ size: CGSize) {
    let mark = size.height * 0.74
    let fontSize = size.height * 0.30
    let gap = size.height * 0.06
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
        .foregroundColor: rgb(0x5F_EC_E6),
    ]
    let text = NSAttributedString(string: "Lagoon", attributes: attributes)
    let textSize = text.size()
    let originX = size.width / 2 - (mark + gap + textSize.width) / 2

    NSGraphicsContext.current?.saveGraphicsState()
    let circle = NSBezierPath(ovalIn: NSRect(
        x: originX, y: size.height / 2 - mark / 2, width: mark, height: mark
    ))
    circle.addClip()
    image.draw(
        in: CGRect(x: originX, y: size.height / 2 - mark / 2, width: mark, height: mark),
        from: .zero, operation: .sourceOver, fraction: 1
    )
    NSGraphicsContext.current?.restoreGraphicsState()

    text.draw(at: CGPoint(
        x: originX + mark + gap,
        y: size.height / 2 - textSize.height / 2
    ))
}

let banner = source("topshelf")
for (name, w, h) in [("Top Shelf Image", 1920, 720), ("Top Shelf Image Wide", 2320, 720)] {
    let imageset = "\(brand)/\(name).imageset"
    let file = name.lowercased().replacingOccurrences(of: " ", with: "-")
    for (suffix, scale) in [("", 1), ("@2x", 2)] {
        let data = render(width: w * scale, height: h * scale, opaque: true) { size in
            if let banner { fill(banner, size) } else { drawLockup(icon, size) }
        }
        write(data, "\(imageset)/\(file)\(suffix).png")
    }
    writeJSON([
        "images": [
            ["filename": "\(file).png", "idiom": "tv", "scale": "1x"],
            ["filename": "\(file)@2x.png", "idiom": "tv", "scale": "2x"],
        ],
        "info": ["author": "import-artwork", "version": 1],
    ], "\(imageset)/Contents.json")
}

print("done")

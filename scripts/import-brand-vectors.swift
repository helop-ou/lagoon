#!/usr/bin/env swift
// Imports the brand package's vector marks into the asset catalogue.
//
//   scripts/import-brand-vectors.swift ../lagoon-branding
//
// Covers the in-app vectors (onboarding lockup, jellyfish accent);
// import-artwork.swift does the raster icon and Top Shelf assets.
//
// Each PDF is cropped to its ink, still as vector. The package pages have
// unequal padding (81pt above the symbol, 58pt below), so without the crop
// `.frame(height:)` would size the padding, not the mark, and `LagoonLockup`'s
// ratios would be off.

import AppKit
import CoreGraphics

let arguments = Array(CommandLine.arguments.dropFirst())
guard let packageRoot = arguments.first, arguments.count == 1 else {
    FileHandle.standardError.write(Data("""
    usage: import-brand-vectors.swift <lagoon-branding directory>

    Expects the Phase 3 package layout: 01_Master_Vector and 07_Secondary_Accent.

    """.utf8))
    exit(1)
}

let catalogue = "Lagoon/Assets.xcassets"

/// name in the catalogue, source path, whether it is tinted at the call site
let marks: [(name: String, source: String, template: Bool)] = [
    ("LagoonSymbol", "01_Master_Vector/Lagoon_Primary_Symbol_Color.pdf", false),
    // Light, not color: the color wordmark is Ink (#07161D), invisible on black.
    ("LagoonWordmark", "01_Master_Vector/Lagoon_Wordmark_Light.pdf", false),
    ("LagoonJellyfish", "07_Secondary_Accent/Lagoon_Jellyfish_Accent.pdf", true),
]

// MARK: - Ink bounds

/// Rasterises the page and returns the tight bounding box of everything with
/// meaningful alpha, in PDF points.
func inkRect(of page: CGPDFPage) -> CGRect {
    let box = page.getBoxRect(.mediaBox)
    let scale: CGFloat = 4
    let width = Int((box.width * scale).rounded(.up))
    let height = Int((box.height * scale).rounded(.up))
    guard width > 0, height > 0,
          let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { return box }
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -box.origin.x, y: -box.origin.y)
    context.drawPDFPage(page)
    guard let data = context.data else { return box }
    let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

    var minX = width, maxX = -1, minY = height, maxY = -1
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 38 { // ~15%
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
    guard maxX >= minX, maxY >= minY else { return box }

    // Bitmap row 0 is the page bottom: both use a bottom-left origin.
    return CGRect(
        x: box.origin.x + CGFloat(minX) / scale,
        y: box.origin.y + CGFloat(minY) / scale,
        width: CGFloat(maxX - minX + 1) / scale,
        height: CGFloat(maxY - minY + 1) / scale
    )
}

// MARK: - Emit

func croppedPDF(_ page: CGPDFPage, to rect: CGRect) -> Data {
    let output = NSMutableData()
    var mediaBox = CGRect(origin: .zero, size: rect.size)
    guard let consumer = CGDataConsumer(data: output),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        FileHandle.standardError.write(Data("error: could not open a PDF context\n".utf8))
        exit(1)
    }
    context.beginPDFPage(nil)
    context.translateBy(x: -rect.origin.x, y: -rect.origin.y)
    context.drawPDFPage(page)
    context.endPDFPage()
    context.closePDF()
    return output as Data
}

func write(_ data: Data, _ path: String) {
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    do { try data.write(to: url) } catch {
        FileHandle.standardError.write(Data("error: \(path): \(error)\n".utf8))
        exit(1)
    }
}

for mark in marks {
    let source = "\(packageRoot)/\(mark.source)"
    guard let document = CGPDFDocument(URL(fileURLWithPath: source) as CFURL),
          let page = document.page(at: 1) else {
        FileHandle.standardError.write(Data("error: cannot read \(source)\n".utf8))
        exit(1)
    }
    let box = page.getBoxRect(.mediaBox)
    let ink = inkRect(of: page)
    let directory = "\(catalogue)/\(mark.name).imageset"
    write(croppedPDF(page, to: ink), "\(directory)/\(mark.name).pdf")

    let intent = mark.template ? "template" : "original"
    write(Data("""
    {
      "images" : [
        {
          "filename" : "\(mark.name).pdf",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      },
      "properties" : {
        "preserves-vector-representation" : true,
        "template-rendering-intent" : "\(intent)"
      }
    }

    """.utf8), "\(directory)/Contents.json")

    let format = { (rect: CGRect) in
        String(format: "%.1f×%.1f", rect.width, rect.height)
    }
    print("\(mark.name): page \(format(box)) → ink \(format(ink))")
}

print("""

Cropped to ink, so `.frame(height:)` sizes the mark itself. LagoonLockup's
ratios are measured from the package's own lockups — re-measure them there if
the artwork changes shape.
""")

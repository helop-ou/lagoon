import CoreGraphics
import ImageIO
import CoreImage
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Lagoon

/// Reads a generated code back the way a camera would: a QR code either
/// decodes or it does not, and that is invisible on screen.
@Suite("QR codes")
@MainActor
struct QRCodeTests {
    private let address = "https://lagoon.helop.dev/privacy/"

    /// Scaled the way the view scales it, to the pixels a TV actually shows.
    private func rendered(
        _ code: CGImage,
        side: CGFloat,
        markShare: CGFloat = 0
    ) throws -> CGImage {
        let pixels = Int(side)
        let context = try #require(CGContext(
            data: nil,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // Matches the view's `.interpolation(.none)`; smoothing blurs modules.
        context.interpolationQuality = .none
        context.draw(code, in: CGRect(x: 0, y: 0, width: side, height: side))

        if markShare > 0 {
            let markSide = side * markShare
            context.setFillColor(CGColor(red: 0.04, green: 0.11, blue: 0.16, alpha: 1))
            context.fill(CGRect(
                x: (side - markSide) / 2,
                y: (side - markSide) / 2,
                width: markSide,
                height: markSide
            ))
        }
        return try #require(context.makeImage())
    }

    /// `CIDetector`, not Vision: Vision fails with "Could not create inference
    /// context" on the tvOS simulator.
    private func decoded(_ image: CGImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    @Test func aGeneratedCodeReadsBackAsTheAddressItWasMadeFrom() throws {
        let code = try #require(QRCode.image(for: address))

        #expect(decoded(try rendered(code, side: Metrics.qrCodeSize)) == [address])
    }

    /// Fails if the mark grows past what correction level H can restore.
    @Test func theCentreMarkStillLeavesACodeThatDecodes() throws {
        let code = try #require(QRCode.image(for: address))

        let covered = try rendered(
            code,
            side: Metrics.qrCodeSize,
            markShare: QRCode.markShare
        )

        #expect(decoded(covered) == [address])
    }

    /// The quiet zone is measured in modules, not points: a shorter address
    /// makes wider modules, so no fixed margin fits every address. Measured
    /// off the rendered view: the finder pattern's top edge is seven modules
    /// wide, and everything between it and the view's edge is margin.
    @Test func theQuietZoneIsAlwaysAtLeastTheSpecifiedFourModules() throws {
        for text in [
            "https://lagoon.helop.dev",
            address,
            "https://lagoon.helop.dev/legal/privacy-policy/full-text/",
        ] {
            let renderer = ImageRenderer(content: QRCodeView(text: text))
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            let finder = try #require(try firstDarkRun(in: image), "\(text) drew no modules")
            let module = CGFloat(finder.length) / 7

            #expect(CGFloat(finder.x) >= module * 4, "\(text) is drawn without a full quiet zone at the side")
            #expect(CGFloat(finder.y) >= module * 4, "\(text) is drawn without a full quiet zone on top")
        }
    }

    /// The top-left finder's top edge: the first dark run in the first row
    /// that has one. Transparent corners read as light.
    private func firstDarkRun(in image: CGImage) throws -> (x: Int, y: Int, length: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Rows run from the top in memory for a bitmap context.
        func isDark(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * width + x) * 4
            let sum = Int(pixels[offset]) + Int(pixels[offset + 1]) + Int(pixels[offset + 2])
            return sum < 3 * 128
        }
        for y in 0..<height {
            guard let x = (0..<width).first(where: { isDark($0, y) }) else { continue }
            let length = (x..<width).prefix { isDark($0, y) }.count
            return (x, y, length)
        }
        return nil
    }

    @Test func aCodeThatCouldNotBeGeneratedStillGetsAMargin() {
        #expect(QRCode.quietZone(side: Metrics.qrCodeSize, modulesAcross: 0) == Metrics.qrCodeMinimumQuietZone)
    }

    /// Renders the real view, not a filled-square stand-in for the mark, and
    /// prints the path of the PNG it writes so the result can be looked at.
    @Test func theRenderedComponentStillDecodes() throws {
        let renderer = ImageRenderer(content: QRCodeView(text: address))
        renderer.scale = 1
        let rendered = try #require(renderer.cgImage)

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lagoon-qr.png")
        if let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) {
            CGImageDestinationAddImage(destination, rendered, nil)
            CGImageDestinationFinalize(destination)
            print("LAGOON_QR_SNAPSHOT \(url.path)")
        }

        #expect(decoded(rendered) == [address])
    }

    @Test func aCodeSurvivesTheLongestAddressLagoonWouldEverShow() throws {
        let long = "https://lagoon.helop.dev/legal/privacy-policy/full-text/"
        let code = try #require(QRCode.image(for: long))

        let covered = try rendered(code, side: Metrics.qrCodeSize, markShare: QRCode.markShare)

        #expect(decoded(covered) == [long])
    }
}

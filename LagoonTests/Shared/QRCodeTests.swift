import CoreGraphics
import ImageIO
import CoreImage
import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Lagoon

/// Reads a generated code back the way a camera would.
///
/// A QR code is the one component whose correctness cannot be judged by
/// looking at it: it either decodes or it does not, and the difference between
/// a code that scans from the sofa and one that does not is invisible on
/// screen. So these decode rather than inspect, and the centre-mark test
/// covers the code the way the view does instead of trusting the arithmetic in
/// `QRCode.markShare`.
@Suite("QR codes")
@MainActor
struct QRCodeTests {
    private let address = "https://lagoon.helop.dev/privacy/"

    /// Scaled the way the view scales it, so what the test decodes is the
    /// number of pixels a television actually puts on the glass.
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
        // The view's `.interpolation(.none)`: smoothing is what blurs the
        // modules into each other and stops a camera finding their edges.
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

    /// Core Image rather than Vision: Vision's barcode request answers
    /// "Could not create inference context" on the tvOS simulator, where this
    /// suite runs. `CIDetector` is plain Core Image and works there.
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

    /// The branding claim, checked rather than asserted. If someone grows the
    /// mark past what correction level H can restore, this fails instead of
    /// the code quietly becoming one that only scans from two feet away.
    @Test func theCentreMarkStillLeavesACodeThatDecodes() throws {
        let code = try #require(QRCode.image(for: address))

        let covered = try rendered(
            code,
            side: Metrics.qrCodeSize,
            markShare: QRCode.markShare
        )

        #expect(decoded(covered) == [address])
    }

    /// The margin around the code is the quiet zone, and a code drawn hard
    /// against other content is one a camera has to hunt for.
    ///
    /// The first version of this fixed the margin at 32 points and failed
    /// here, which is the reason it is measured from the code instead: a
    /// shorter address makes fewer, wider modules and therefore needs a wider
    /// margin, so no single constant is right for every address.
    @Test func theQuietZoneIsAlwaysAtLeastTheSpecifiedFourModules() throws {
        for text in [
            "https://lagoon.helop.dev",
            address,
            "https://lagoon.helop.dev/legal/privacy-policy/full-text/",
        ] {
            let code = try #require(QRCode.image(for: text))
            let module = Metrics.qrCodeSize / CGFloat(code.width)

            let zone = QRCode.quietZone(side: Metrics.qrCodeSize, modulesAcross: code.width)

            #expect(zone >= module * 4, "\(text) is drawn without a full quiet zone")
        }
    }

    @Test func aCodeThatCouldNotBeGeneratedStillGetsAMargin() {
        #expect(QRCode.quietZone(side: Metrics.qrCodeSize, modulesAcross: 0) > 0)
    }

    /// The finished component, drawn the way the sheet draws it and read back
    /// the way a camera would.
    ///
    /// The other tests approximate the centre mark with a filled square. This
    /// one renders the real view — white plate, dark tile, jellyfish, quiet
    /// zone and all — so the thing under test is the thing on screen. It also
    /// writes the image into the simulator's temporary directory and prints
    /// the path, which is how the mark's proportions get looked at without
    /// waiting for a television.
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

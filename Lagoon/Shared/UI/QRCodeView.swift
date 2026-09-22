import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// QR generation, apart from the view so a test can decode the result.
enum QRCode {
    /// The centre plate's share of the code's width, gap included. About 6%
    /// of the area, well inside level H's ~30% recovery. `QRCodeTests`
    /// decodes a covered code to prove it.
    static let markShare: CGFloat = 0.30

    /// Margin around the symbol inside the plate, so it doesn't touch live
    /// modules.
    static let markInsetShare: CGFloat = 0.20

    /// Rounding as a share of size, so it scales.
    static let markCornerShare: CGFloat = 0.26

    /// Shared: building a `CIContext` is the expensive part.
    private static let context = CIContext(options: nil)

    /// The four-module quiet zone the spec requires. Derived, not a token:
    /// a shorter address makes larger modules.
    static func quietZone(side: CGFloat, modulesAcross: Int) -> CGFloat {
        guard modulesAcross > 0 else { return Metrics.qrCodeMinimumQuietZone }
        return max(Metrics.qrCodeMinimumQuietZone, side / CGFloat(modulesAcross) * 4)
    }

    /// Cached per address (only two exist). Keeps the view synchronous, so
    /// `ImageRenderer` can draw it in a test.
    private static var generated: [String: CGImage] = [:]

    static func image(for text: String) -> CGImage? {
        if let cached = generated[text] { return cached }
        let made = generate(text)
        if let made { generated[text] = made }
        return made
    }

    private static func generate(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // H pays for the centre mark and poor scanning conditions.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }

        // Brand Ink on Mist, about 16:1 contrast. The pair must stay
        // extreme; never tint the light half toward the accent.
        let tint = CIFilter.falseColor()
        tint.inputImage = output
        tint.color0 = CIColor(red: 0x07 / 255, green: 0x16 / 255, blue: 0x1D / 255)
        tint.color1 = CIColor(red: 0xE9 / 255, green: 0xF1 / 255, blue: 0xF2 / 255)
        guard let tinted = tint.outputImage else { return nil }
        return context.createCGImage(tinted, from: tinted.extent)
    }
}

/// A QR code for handing an address from the TV to a phone.
///
/// **Deliberately plain square modules.** Rounded or dotted modules lose
/// contrast, and a sofa is a bad place to scan from. The branding is the
/// centre mark only.
struct QRCodeView: View {
    let text: String
    var side: CGFloat = Metrics.qrCodeSize

    private var code: CGImage? { QRCode.image(for: text) }

    private var quietZone: CGFloat {
        QRCode.quietZone(side: side, modulesAcross: code?.width ?? 0)
    }

    var body: some View {
        Group {
            if let code {
                Image(decorative: code, scale: 1)
                    // One pixel per module: smoothing would blur the edges
                    // a camera looks for.
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
                    .overlay(mark)
            } else {
                // Every caller also shows the address as text.
                Color.lagoonMist.frame(width: side, height: side)
            }
        }
        .padding(quietZone)
        .background(Color.lagoonMist, in: .rect(cornerRadius: Metrics.cardCornerRadius))
        // The address is already on screen as text.
        .accessibilityHidden(true)
    }

    /// The Lagoon symbol on a Mist plate. Not the jellyfish: brand rules
    /// restrict it to loading, empty and atmospheric moments.
    private var mark: some View {
        let plate = side * QRCode.markShare
        return Image("LagoonSymbol")
            .resizable()
            .scaledToFit()
            .padding(plate * QRCode.markInsetShare)
            .frame(width: plate, height: plate)
            .background(
                Color.lagoonMist,
                in: .rect(cornerRadius: plate * QRCode.markCornerShare, style: .continuous)
            )
    }
}

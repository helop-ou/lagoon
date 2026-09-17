import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The code itself, apart from the view that draws it, so a test can generate
/// one and read it back the way a camera would.
enum QRCode {
    /// The white plate's share of the code's width: everything the mark
    /// covers, gap included.
    ///
    /// Correction level H restores roughly 30% of a damaged code, and a mark
    /// covering this much of the width occupies about 6% of its area — well
    /// inside the budget, with the rest left for the room. Pushing past about
    /// a quarter of the width is where covering the code starts competing
    /// with the conditions it has to survive. `QRCodeTests` decodes a covered
    /// code rather than trusting that arithmetic.
    static let markShare: CGFloat = 0.30

    /// How much of the plate is margin around the symbol. The rest of the
    /// plate is the gap, which is what makes the mark read as a deliberate
    /// hole punched in the pattern rather than a sticker dropped on top of
    /// it. Without it the symbol sits directly against live modules and the
    /// whole thing looks pasted on.
    static let markInsetShare: CGFloat = 0.20

    /// Rounding, as a share of whatever is being rounded, so the plate and
    /// the tile curve alike at any size.
    static let markCornerShare: CGFloat = 0.26

    /// One context for the app. Building a `CIContext` is the expensive part;
    /// the render itself is a few hundred pixels and happens once per address.
    private static let context = CIContext(options: nil)

    /// The white margin a code needs around it, for a code of this many
    /// modules drawn at this size.
    ///
    /// Derived rather than a fixed token, because the right answer moves with
    /// the content: the specification asks for four modules, and a short
    /// address makes fewer, larger modules than a long one. A constant sized
    /// for one address is too small for a shorter one, which is exactly what
    /// `QRCodeTests` caught.
    static func quietZone(side: CGFloat, modulesAcross: Int) -> CGFloat {
        guard modulesAcross > 0 else { return Metrics.qrCodeMinimumQuietZone }
        return max(Metrics.qrCodeMinimumQuietZone, side / CGFloat(modulesAcross) * 4)
    }

    /// Generated codes, kept because the view asks for one every time SwiftUI
    /// rebuilds it. There are two addresses in the whole app, so this never
    /// grows, and holding them makes the view synchronous — which is what lets
    /// `ImageRenderer` draw the finished thing for a test to read back.
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
        // H, the highest level, is what pays for the centre mark and for the
        // room. The addresses here are short enough that the extra redundancy
        // costs no meaningful density.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }

        // Ink on Mist rather than black on white: the brand package names
        // those two as its monochrome dark and its light background, so the
        // code is Lagoon's own colours without anyone choosing them. The cost
        // is small and measurable — Ink on Mist is about 16:1 where black on
        // white is 21:1, both far above anything a scanner needs. It is the
        // *pair* that has to stay extreme; tinting the light half toward the
        // accent is what would actually break it.
        let tint = CIFilter.falseColor()
        tint.inputImage = output
        tint.color0 = CIColor(red: 0x07 / 255, green: 0x16 / 255, blue: 0x1D / 255)
        tint.color1 = CIColor(red: 0xE9 / 255, green: 0xF1 / 255, blue: 0xF2 / 255)
        guard let tinted = tint.outputImage else { return nil }
        return context.createCGImage(tinted, from: tinted.extent)
    }
}

/// A QR code for handing an address to a phone.
///
/// Apple TV has no browser, so an address Lagoon puts on screen is one the
/// viewer has to type on another device. A code they can point a camera at
/// removes that, and the television is the one screen where it always earns
/// its space.
///
/// **Deliberately plain.** Square modules, black on white, nothing styled
/// about the modules themselves. A sofa is the worst place anyone will ever
/// scan a code from: three metres away, off-axis, through whatever the room's
/// lights are doing to a glossy panel. Rounded or dotted modules shrink the
/// dark area each one contributes, which costs contrast exactly where the
/// distance has already taken it. The branding is the centre mark instead,
/// which is the one decoration the format is actually built to absorb.
struct QRCodeView: View {
    let text: String
    var side: CGFloat = Metrics.qrCodeSize

    private var code: CGImage? { QRCode.image(for: text) }

    /// Four modules of white around the code, measured from the code that was
    /// actually generated rather than assumed.
    private var quietZone: CGFloat {
        QRCode.quietZone(side: side, modulesAcross: code?.width ?? 0)
    }

    var body: some View {
        Group {
            if let code {
                Image(decorative: code, scale: 1)
                    // The generator emits one pixel per module, so this is
                    // about thirty pixels square. Smoothed up to 420 points
                    // the modules blur into each other and a camera cannot
                    // find their edges; nearest-neighbour keeps them square.
                    .interpolation(.none)
                    .resizable()
                    .frame(width: side, height: side)
                    .overlay(mark)
            } else {
                // Generation does not fail in practice, but a blank card is
                // better than a broken-image glyph, and every caller shows
                // the address in type beside this.
                Color.lagoonMist.frame(width: side, height: side)
            }
        }
        .padding(quietZone)
        .background(Color.lagoonMist, in: .rect(cornerRadius: Metrics.cardCornerRadius))
        // The address is already on screen as text, and VoiceOver reading it
        // twice is worse than not describing a thing nobody can hear anyway.
        .accessibilityHidden(true)
    }

    /// The jellyfish on its own dark tile, the way the Helop code carries the
    /// `h_` lockup: a deliberate hole in the pattern rather than a smudge over
    /// it. Lagoon's mark rather than Helop's, because this is inside Lagoon,
    /// shown to Lagoon's viewers.
    /// The symbol, on the Mist plate that punches the hole.
    ///
    /// The symbol rather than the jellyfish: the jellyfish is the package's
    /// *secondary* mark, restricted to "punctuation in loading, empty-state or
    /// atmospheric moments … small, one-color, and low contrast", which the
    /// middle of an identity mark is none of. It also carries no plate of its
    /// own, because the symbol is two-tone and its navy half would vanish into
    /// one.
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

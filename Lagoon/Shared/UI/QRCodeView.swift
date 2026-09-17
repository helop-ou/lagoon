import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The code itself, apart from the view that draws it, so a test can generate
/// one and read it back the way a camera would.
enum QRCode {
    /// The centre mark's share of the code's width.
    ///
    /// Correction level H restores roughly 30% of a damaged code, and a mark
    /// covering this much of the width occupies about 6% of its area — well
    /// inside the budget, with the rest left for the room. Pushing past about
    /// a quarter of the width is where covering the code starts competing
    /// with the conditions it has to survive. `QRCodeTests` decodes a covered
    /// code rather than trusting that arithmetic.
    static let markShare: CGFloat = 0.24

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

    static func image(for text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        // H, the highest level, is what pays for the centre mark and for the
        // room. The addresses here are short enough that the extra redundancy
        // costs no meaningful density.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        return context.createCGImage(output, from: output.extent)
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

    @State private var code: CGImage?

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
                Color.white.frame(width: side, height: side)
            }
        }
        .padding(quietZone)
        .background(.white, in: .rect(cornerRadius: Metrics.cardCornerRadius))
        // The address is already on screen as text, and VoiceOver reading it
        // twice is worse than not describing a thing nobody can hear anyway.
        .accessibilityHidden(true)
        .task(id: text) { code = QRCode.image(for: text) }
    }

    /// The jellyfish on its own dark tile, the way the Helop code carries the
    /// `h_` lockup: a deliberate hole in the pattern rather than a smudge over
    /// it. Lagoon's mark rather than Helop's, because this is inside Lagoon,
    /// shown to Lagoon's viewers.
    private var mark: some View {
        Canvas { context, size in
            let unit = min(
                size.width / JellyfishGeometry.canvas.width,
                size.height / JellyfishGeometry.canvas.height
            )
            var jellyfish = context
            jellyfish.translateBy(
                x: (size.width - JellyfishGeometry.canvas.width * unit) / 2,
                y: (size.height - JellyfishGeometry.canvas.height * unit) / 2
            )
            jellyfish.scaleBy(x: unit, y: unit)
            // At rest: contraction 0 is the supplied artwork, not a pose.
            JellyfishGeometry.stroke(
                in: &jellyfish,
                contraction: 0,
                trail: 0,
                with: .color(.lagoonAqua)
            )
        }
        .padding(side * QRCode.markShare * 0.17)
        .frame(width: side * QRCode.markShare, height: side * QRCode.markShare)
        .background(Color.lagoonNavy, in: .rect(cornerRadius: Metrics.badgeCornerRadius))
    }
}

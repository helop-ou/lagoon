import Foundation
import Testing
#if os(tvOS)
import UIKit
#endif
@testable import Lagoon

/// The composite has to survive JPEG encoding: the extension only points
/// tvOS at these files, so a composite that will not encode means no artwork.
@Suite("Top Shelf artwork")
struct TopShelfArtworkTests {
    #if os(tvOS)
    private func backdrop() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1920, height: 1080), format: format)
            .image { context in
                UIColor.systemTeal.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1920, height: 1080))
            }
    }

    @Test func aComposedCarouselImageEncodesAsJPEG() {
        // `jpegData` returns nil for an extended-range bitmap, which only an
        // HDR television hands out; the SDR simulator encodes either way, so
        // pin the 8-bit standard range the renderer is given.
        let format = TopShelfArtwork.opaqueFormat()
        #expect(format.preferredRange == .standard)
        #expect(format.opaque)

        for size in [TopShelfArtwork.scale2x, TopShelfArtwork.scale1x] {
            let composed = TopShelfArtwork.compose(
                backdrop: backdrop(),
                logo: nil,
                title: "Dune",
                size: size
            )

            #expect(composed.size == size)
            #expect(composed.jpegData(compressionQuality: 0.9) != nil)
        }
    }

    @Test func theRendererNeverAsksTheScreenWhatFormatToUse() {
        // `UIGraphicsImageRendererFormat.preferred()` takes scale and
        // extended range from the screen, which gives a wide-range bitmap on
        // an HDR TV (never on the SDR simulator). Pinning scale 1 is the
        // observable half: the size is already in pixels.
        let composed = TopShelfArtwork.compose(
            backdrop: backdrop(),
            logo: nil,
            title: "Dune",
            size: TopShelfArtwork.scale2x
        )

        #expect(composed.scale == 1)
        #expect(composed.size == CGSize(width: 3840, height: 2160))
    }

    @Test func artworkLivesSomewhereTvOSWillLetItBeWritten() throws {
        // Apple TV allows 500 KB of persistent storage and the rest must be
        // purgeable; the container root is refused on device, not in the sim.
        #expect(TopShelfArtwork.containerSubpath.hasPrefix("Library/Caches/"))

        // The extension hard-codes the container and directory it reads.
        let provider = try TopShelfExtensionSource()
        #expect(provider.stringConstant("artworkDirectory") == TopShelfArtwork.containerSubpath)
        #expect(provider.stringConstant("appGroupID") == TopShelfStore.appGroupID)
    }
    #endif
}

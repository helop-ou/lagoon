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

    @Test func artworkLivesSomewhereTvOSWillLetItBeWritten() {
        // Apple TV allows 500 KB of persistent storage and the rest must be
        // purgeable; the container root is refused on device, not in the sim.
        #expect(TopShelfArtwork.containerSubpath.hasPrefix("Library/Caches/"))

        // LagoonTopShelf/ContentProvider.swift hard-codes this path, so pin
        // the literal.
        #expect(TopShelfArtwork.containerSubpath == "Library/Caches/TopShelf")
    }

    @Test func artworkIsThrownAwayWhenTheLayoutChanges() {
        // The cache is keyed by item id forever; only the version invalidates it.
        let suite = "TopShelfArtworkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(defaults.integer(forKey: "topShelf.artworkLayoutVersion") == 0)
        TopShelfArtwork.discardArtworkFromEarlierLayouts(
            defaults: defaults,
            appGroupID: TopShelfStore.appGroupID
        )
        #expect(
            defaults.integer(forKey: "topShelf.artworkLayoutVersion")
                == TopShelfArtwork.layoutVersion
        )
    }
    #endif
}

import Foundation
import Testing
#if os(tvOS)
import UIKit
#endif
@testable import Lagoon

/// The composite has to survive being turned into a JPEG.
///
/// This is the whole output of the feature: the extension draws nothing of
/// its own, it points tvOS at these files. A composite that renders fine and
/// then will not encode is indistinguishable from no artwork at all, which is
/// exactly how it presented — "no artwork could be built for any of 8 titles"
/// on an Apple TV while every simulator managed all eight.
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
        // `UIGraphicsImageRendererFormat.preferred()` reads the main screen's
        // configuration, per Apple's own header, for both the scale and the
        // extended-range setting. On an Apple TV attached to an HDR
        // television that yields a wide-range bitmap; the simulator's screen
        // is SDR, so it never showed there.
        //
        // Pinning the composite's own scale is the observable half of that:
        // a preferred format would apply the screen scale on top of a size
        // already given in pixels.
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
        // An Apple TV allows an app 500 KB of persistent local storage and
        // requires the rest to be purgeable, so writing composites at the
        // container root is refused on device while every simulator, whose
        // container is a plain directory on a Mac, accepts them. Build 60
        // reported "could not write to the shared container" for all eight.
        #expect(TopShelfArtwork.containerSubpath.hasPrefix("Library/Caches/"))

        // LagoonTopShelf/ContentProvider.swift resolves this same path by
        // hand against its own container, because an app extension cannot
        // import the app's module. This is the only thing holding the two in
        // step, so it pins the literal rather than the shape.
        #expect(TopShelfArtwork.containerSubpath == "Library/Caches/TopShelf")
    }

    @Test func artworkIsThrownAwayWhenTheLayoutChanges() {
        // The cache is keyed by item id and reused forever, so the version is
        // the only thing that can invalidate a redraw.
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

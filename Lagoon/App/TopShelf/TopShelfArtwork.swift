import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the full-screen images the Top Shelf carousel shows.
///
/// **The carousel has no title to set.** `TVTopShelfCarouselItem` inherits
/// only `playAction`, `displayAction` and `setImageURL` from
/// `TVTopShelfItem`, and adds `contextTitle`, `summary`, `genre` and
/// `duration`. There is no `title` property the way `TVTopShelfSectionedItem`
/// has one, so the name of the thing has to be part of the artwork. That is
/// also what the Apple TV app does.
///
/// The app composes and the extension only reads, which keeps to the rule
/// that the extension holds no credentials and does no networking: these are
/// finished JPEGs in the shared container, addressed by file URL.
nonisolated enum TopShelfArtwork {
    /// Full screen at @2x. tvOS lays out in 1920x1080 points.
    static let scale2x = CGSize(width: 3840, height: 2160)
    static let scale1x = CGSize(width: 1920, height: 1080)

    // Composed images live in their own directory, so the whole set can be
    // replaced on each publish without touching anything else shared. See
    // `containerSubpath` for where that directory is and why.

    /// Bumped whenever `compose` would draw the same inputs differently.
    ///
    /// Artwork is cached by item id and reused forever, so without this a
    /// viewer upgrading from a build with a different layout keeps the old
    /// pictures indefinitely — the file name never changes, only what is
    /// inside it. 1 was the bottom-left title; 2 is the top-left one.
    static let layoutVersion = 2
    private static let layoutVersionKey = "topShelf.artworkLayoutVersion"

    /// Throws away everything composed by an earlier layout. A no-op on the
    /// common path, since the version matches after the first publish.
    static func discardArtworkFromEarlierLayouts(defaults: UserDefaults, appGroupID: String) {
        guard defaults.integer(forKey: layoutVersionKey) != layoutVersion else { return }
        removeArtwork(notIn: [], appGroupID: appGroupID)
        defaults.set(layoutVersion, forKey: layoutVersionKey)
    }

    #if os(tvOS)
    /// Composes one carousel image: the backdrop, a scrim heavy enough for
    /// text to survive over any still, and the title as artwork.
    ///
    /// Jellyfin's logo art is preferred where a title has it, because it is
    /// the treatment the studio intended and it is what Home's hero already
    /// uses. Where there is none, the title is set in type instead, which is
    /// the same fallback `TitleArtImage` makes.
    static func compose(
        backdrop: UIImage,
        logo: UIImage?,
        title: String,
        size: CGSize
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size, format: opaqueFormat())
        return renderer.image { context in
            draw(backdrop: backdrop, in: size)
            drawScrim(in: size, context: context.cgContext)
            drawTitle(logo: logo, title: title, in: size)
        }
    }

    /// A format that depends on nothing outside this function.
    ///
    /// `UIGraphicsImageRendererFormat.preferred()` reads the main screen's
    /// current configuration for both `scale` and extended range. On an Apple
    /// TV attached to an HDR television that returns an extended-range format,
    /// and **`jpegData` returns nil for an extended-range image** — every
    /// composite failed with "no artwork could be built for any of 8 titles".
    /// The simulator's screen is SDR, which is why it never showed there.
    /// Reading the main screen from `render`'s background thread was a second
    /// problem in the same call.
    ///
    /// Nothing was gained by asking: `scale` and `opaque` were overridden
    /// immediately, and the output is a JPEG in a shared container, not
    /// something drawn to this screen.
    private static func opaqueFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        // The renderer is already working in pixels; letting it apply the
        // screen scale again would quadruple a 3840x2160 bitmap.
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return format
    }

    /// Aspect-fill, centred. A backdrop is 16:9 like the screen, so this is
    /// usually a straight resize, but a source that is not must crop rather
    /// than letterbox: bars on the Top Shelf look broken.
    private static func draw(backdrop: UIImage, in size: CGSize) {
        let imageSize = backdrop.size
        guard imageSize.width > 0, imageSize.height > 0 else {
            UIColor.black.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            return
        }
        let scale = max(size.width / imageSize.width, size.height / imageSize.height)
        let scaled = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        backdrop.draw(in: CGRect(
            x: (size.width - scaled.width) / 2,
            y: (size.height - scaled.height) / 2,
            width: scaled.width,
            height: scaled.height
        ))
    }

    /// Darkens the top-left corner the title occupies and leaves the rest of
    /// the still alone, the same reasoning as the hero's wash: the picture is
    /// the point, the scrim only has to make the text legible.
    private static func drawScrim(in size: CGSize, context: CGContext) {
        let colors = [
            UIColor.black.withAlphaComponent(0.85).cgColor,
            UIColor.black.withAlphaComponent(0.35).cgColor,
            UIColor.clear.cgColor,
        ] as CFArray
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors,
            locations: [0, 0.45, 1]
        ) else { return }
        // The renderer's context is UIKit-oriented, so y grows downwards and
        // the top of the image is y = 0.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: size.height * 0.65),
            options: []
        )
    }

    private static func drawTitle(logo: UIImage?, title: String, in size: CGSize) {
        // The tvOS title-safe area is 5% in from every edge. The title hangs
        // from the top edge rather than sitting on the bottom one, which also
        // keeps it clear of the carousel's own buttons.
        let inset = size.width * 0.06
        let maxWidth = size.width * 0.5
        let top = size.height * 0.08

        if let logo, logo.size.width > 0, logo.size.height > 0 {
            let maxHeight = size.height * 0.18
            let scale = min(maxWidth / logo.size.width, maxHeight / logo.size.height)
            let drawn = CGSize(width: logo.size.width * scale, height: logo.size.height * scale)
            logo.draw(in: CGRect(
                x: inset,
                y: top,
                width: drawn.width,
                height: drawn.height
            ))
            return
        }

        let font = UIFont.systemFont(ofSize: size.height * 0.075, weight: .bold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let bounding = CGSize(width: maxWidth, height: size.height * 0.2)
        let rect = (title as NSString).boundingRect(
            with: bounding,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
        (title as NSString).draw(
            with: CGRect(
                x: inset,
                y: top,
                width: bounding.width,
                height: rect.height
            ),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }
    #endif

    /// Where composed artwork lives inside the App Group container.
    ///
    /// **`Library/Caches`, because tvOS allows nothing else.** An Apple TV
    /// gives 500 KB of persistent storage through `NSUserDefaults`; everything
    /// beyond must be purgeable. Sixteen 4K-class JPEGs at the container root
    /// is not, and a device refuses the write — build 60 reported "could not
    /// write to the shared container" for all eight titles while simulators
    /// wrote them happily.
    ///
    /// Purgeable is honest anyway: the artwork is derived, keyed by item id,
    /// and `publishIfEmpty` redraws it when the directory comes back empty.
    ///
    /// **Mirrored by `ContentProvider.artworkDirectory`** — change one, change
    /// the other.
    static let containerSubpath = "Library/Caches/TopShelf"

    /// The shared directory, created on demand. Nil when the App Group is not
    /// provisioned or the directory cannot be made, both of which leave
    /// `TopShelfStore` on its no-op path with something to report.
    static func directoryURL(appGroupID: String) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let directory = container.appending(path: containerSubpath)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            // Swallowed with `try?` until now, which meant a container that
            // could not be written to still handed back a usable-looking URL
            // and failed one layer further down.
            return nil
        }
        return directory
    }

    /// Removes composed images that no longer belong to any published item.
    /// The shared container is not a cache the system will trim, so stale
    /// 4K JPEGs would accumulate for every title ever resumed.
    static func removeArtwork(notIn keep: Set<String>, appGroupID: String) {
        guard let directory = directoryURL(appGroupID: appGroupID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

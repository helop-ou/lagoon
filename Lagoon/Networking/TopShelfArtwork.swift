import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the full-screen images the Top Shelf carousel shows (HEL-119).
///
/// **The carousel has no title to set.** `TVTopShelfCarouselItem` inherits
/// only `playAction`, `displayAction` and `setImageURL` from
/// `TVTopShelfItem`, and adds `contextTitle`, `summary`, `genre` and
/// `duration`. There is no `title` property the way `TVTopShelfSectionedItem`
/// has one, so the name of the thing has to be part of the artwork. That is
/// also what the Apple TV app does.
///
/// The app composes and the extension only reads, which keeps HEL-37's rule
/// that the extension holds no credentials and does no networking: these are
/// finished JPEGs in the shared container, addressed by file URL.
enum TopShelfArtwork {
    /// Full screen at @2x. tvOS lays out in 1920x1080 points.
    static let scale2x = CGSize(width: 3840, height: 2160)
    static let scale1x = CGSize(width: 1920, height: 1080)

    /// Where composed images live inside the App Group container. Kept apart
    /// so the whole directory can be replaced on each publish without
    /// touching anything else shared.
    static let directoryName = "TopShelf"

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

    private static func opaqueFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat.preferred()
        // The renderer is already working in pixels; letting it apply the
        // screen scale again would quadruple a 3840x2160 bitmap.
        format.scale = 1
        format.opaque = true
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

    /// The shared directory, created on demand. Nil when the App Group is not
    /// provisioned, which is the same no-op path `TopShelfStore` takes.
    static func directoryURL(appGroupID: String) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        ) else { return nil }
        let directory = container.appending(path: directoryName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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

import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Builds the full-screen images the Top Shelf carousel shows.
///
/// `TVTopShelfCarouselItem` has no `title`, so the name is drawn into the
/// artwork. The app composes finished JPEGs into the shared container; the
/// extension only reads them, so it needs no credentials or network.
nonisolated enum TopShelfArtwork {
    /// Full screen at @2x. tvOS lays out in 1920x1080 points.
    static let scale2x = CGSize(width: 3840, height: 2160)
    static let scale1x = CGSize(width: 1920, height: 1080)

    /// Bump whenever `compose` would draw the same inputs differently.
    /// Artwork is cached by item id, so without a bump upgraders keep the old
    /// pictures forever.
    static let layoutVersion = 2
    private static let layoutVersionKey = "topShelf.artworkLayoutVersion"

    static func discardArtworkFromEarlierLayouts(defaults: UserDefaults, appGroupID: String) {
        guard defaults.integer(forKey: layoutVersionKey) != layoutVersion else { return }
        removeArtwork(notIn: [], appGroupID: appGroupID)
        defaults.set(layoutVersion, forKey: layoutVersionKey)
    }

    #if os(tvOS)
    /// Composes one carousel image: backdrop, scrim, and the title as logo
    /// art, or as type when there is no logo (as `TitleArtImage` does).
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

    /// Never `.preferred()`: on an HDR television that returns an
    /// extended-range format, and `jpegData` returns nil for extended-range
    /// images (the SDR simulator hides this). It also reads the main screen
    /// off the main thread.
    private static func opaqueFormat() -> UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        // Sizes are already pixels; screen scale would quadruple the bitmap.
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return format
    }

    /// Aspect-fill, centred: crop rather than letterbox, since bars on the
    /// Top Shelf look broken.
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

    /// Darkens only the top-left corner the title occupies.
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
        // UIKit-oriented context: y = 0 is the top.
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: 0),
            end: CGPoint(x: 0, y: size.height * 0.65),
            options: []
        )
    }

    private static func drawTitle(logo: UIImage?, title: String, in size: CGSize) {
        // Inside the 5% title-safe area, and at the top to stay clear of the
        // carousel's buttons.
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
    /// Must be under `Library/Caches`: a real Apple TV allows only 500 KB of
    /// persistent storage and refuses the write elsewhere (simulators do not).
    /// `publishIfEmpty` redraws the artwork if the system purges it.
    ///
    /// Mirrored by `ContentProvider.artworkDirectory`; change both.
    static let containerSubpath = "Library/Caches/TopShelf"

    /// The shared directory, created on demand. Nil when the App Group is not
    /// provisioned or the directory cannot be made.
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
            return nil
        }
        return directory
    }

    /// Removes composed images that no longer belong to any published item,
    /// so stale 4K JPEGs do not pile up.
    static func removeArtwork(notIn keep: Set<String>, appGroupID: String) {
        guard let directory = directoryURL(appGroupID: appGroupID),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        for name in names where !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appending(path: name))
        }
    }
}

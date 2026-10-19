import SwiftUI
import Testing
import UIKit

/// Renders a view and compares it with a reference PNG, so a change to how
/// a component looks fails the unit suite like a change to what it does.
///
/// References live in `Snapshots/<Suite>/<name>.<platform>.png` at the
/// repository root, outside the test target so they are never bundled. A
/// missing reference is recorded and the test fails; recording is deleting
/// the PNG and running once, then looking at what was written before
/// committing it. A mismatch writes `<name>.<platform>.failed.png` (what
/// rendered) and `<name>.<platform>.diff.png` (the reference dimmed, changed
/// pixels red) beside the reference, attaches both and the reference to the
/// result, and names the changed region. Both runtimes CI uses are the
/// ones developers run, so references compare exactly; the tolerance only
/// absorbs anti-aliasing noise.
@MainActor
enum Snapshot {
    /// Renders at one pixel per point, so references stay small and do not
    /// depend on the simulator's screen.
    static let scale: CGFloat = 1

    static func verify(
        _ view: some View,
        named name: String,
        size: CGSize,
        tolerance: Double = 0.002,
        filePath: String = #filePath,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let image = try #require(await render(view, size: size), "The view did not render", sourceLocation: sourceLocation)
        let png = try #require(UIImage(cgImage: image).pngData(), sourceLocation: sourceLocation)

        let reference = referenceURL(for: name, filePath: filePath)
        let failed = reference.deletingPathExtension().appendingPathExtension("failed.png")
        let diff = reference.deletingPathExtension().appendingPathExtension("diff.png")
        try? FileManager.default.removeItem(at: failed)
        try? FileManager.default.removeItem(at: diff)

        guard let expected = UIImage(contentsOfFile: reference.path)?.cgImage else {
            try FileManager.default.createDirectory(
                at: reference.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try png.write(to: reference)
            Issue.record(
                "Recorded \(reference.lastPathComponent); look at it, then run again.",
                sourceLocation: sourceLocation
            )
            return
        }

        let comparison = compare(image, with: expected)
        guard comparison.fraction > tolerance else { return }
        try? png.write(to: failed)
        Attachment.record(png, named: failed.lastPathComponent)
        if let referencePNG = try? Data(contentsOf: reference) {
            Attachment.record(referencePNG, named: reference.lastPathComponent)
        }
        var files = failed.lastPathComponent
        if let diffPNG = comparison.diff.flatMap({ UIImage(cgImage: $0).pngData() }) {
            try? diffPNG.write(to: diff)
            Attachment.record(diffPNG, named: diff.lastPathComponent)
            files += " and \(diff.lastPathComponent)"
        }
        Issue.record(
            Comment(rawValue: "\(name) \(comparison.summary(actual: image, expected: expected)); see \(files)."),
            sourceLocation: sourceLocation
        )
    }

    /// Draws the view in an off-screen window, not with `ImageRenderer`,
    /// which leaves `ScrollView` and `NavigationStack` blank. The stack is
    /// there because an iOS `NavigationLink` outside one draws as disabled.
    private static func render(_ view: some View, size: CGSize) async -> CGImage? {
        // No safe area (tvOS insets for overscan) and no scroll-edge blur
        // (iOS softens content under the hidden bar): a component is drawn
        // as it is, not as the screen it sits on would frame it.
        let host = UIHostingController(rootView: NavigationStack {
            framed(view, size: size)
                .ignoresSafeArea()
                .toolbar(.hidden)
                #if os(iOS)
                .scrollEdgeEffectHidden(true, for: .all)
                #endif
        })
        host.view.backgroundColor = .black
        host.safeAreaRegions = []
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
            .map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .dark
        window.rootViewController = host
        // Shown but never key, so tvOS focus never lifts a card.
        window.isHidden = false
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        // A few turns for SwiftUI to commit its first frame.
        for _ in 0..<3 { await Task.yield() }
        host.view.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }.cgImage
    }

    /// The fixed surroundings every snapshot renders in: dark, English,
    /// default text size, one point per pixel.
    private static func framed(_ view: some View, size: CGSize) -> some View {
        view
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .environment(\.locale, Locale(identifier: "en_US"))
            .environment(\.dynamicTypeSize, .large)
            .environment(\.displayScale, scale)
    }

    static var platform: String {
        #if os(tvOS)
        "tvOS"
        #else
        "iOS"
        #endif
    }

    private static func referenceURL(for name: String, filePath: String) -> URL {
        let file = URL(fileURLWithPath: filePath)
        var root = file.deletingLastPathComponent()
        while root.lastPathComponent != "LagoonTests", root.pathComponents.count > 1 {
            root.deleteLastPathComponent()
        }
        return root.deletingLastPathComponent()
            .appending(path: "Snapshots")
            .appending(path: file.deletingPathExtension().lastPathComponent)
            .appending(path: "\(name).\(platform).png")
    }

    /// What differs between a rendering and its reference.
    struct Comparison {
        /// The share of pixels that differ; 1 when the sizes do.
        let fraction: Double
        /// The smallest rectangle holding every changed pixel, from the top
        /// left. Nil when nothing changed or the sizes differ.
        let bounds: CGRect?
        /// The reference dimmed to a third, with every changed pixel red.
        /// Nil when the sizes differ, as there is nothing to lay one on.
        let diff: CGImage?

        func summary(actual: CGImage, expected: CGImage) -> String {
            guard let bounds else {
                return "is \(actual.width)×\(actual.height) but its reference is \(expected.width)×\(expected.height)"
            }
            return String(
                format: "differs from its reference in %.2f%% of pixels, within x %d–%d, y %d–%d",
                fraction * 100,
                Int(bounds.minX), Int(bounds.maxX) - 1, Int(bounds.minY), Int(bounds.maxY) - 1
            )
        }
    }

    /// A pixel differs when any channel moves by more than a rounding step.
    nonisolated static func compare(_ actual: CGImage, with expected: CGImage) -> Comparison {
        guard actual.width == expected.width, actual.height == expected.height else {
            return Comparison(fraction: 1, bounds: nil, diff: nil)
        }
        let width = actual.width, height = actual.height
        let rendered = rgba(actual)
        var marked = rgba(expected)
        var differing = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let pixel = (y * width + x) * 4
                var differs = false
                for channel in 0..<4 where abs(Int(rendered[pixel + channel]) - Int(marked[pixel + channel])) > 8 {
                    differs = true
                    break
                }
                if differs {
                    differing += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                    marked[pixel] = 255
                    marked[pixel + 1] = 0
                    marked[pixel + 2] = 0
                    marked[pixel + 3] = 255
                } else {
                    // Premultiplied, so dimming the colour channels keeps
                    // alpha valid.
                    for channel in 0..<3 { marked[pixel + channel] /= 3 }
                }
            }
        }
        let bounds = maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return Comparison(
            fraction: Double(differing) / Double(width * height),
            bounds: bounds,
            diff: image(from: marked, width: width, height: height)
        )
    }

    private nonisolated static func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Top row first, as `compare` reports positions.
    private nonisolated static func rgba(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }
}

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
/// committing it. A mismatch writes `<name>.<platform>.failed.png` beside the
/// reference and attaches it to the result. Both runtimes CI uses are the
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
        try? FileManager.default.removeItem(at: failed)

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

        let difference = differingFraction(image, expected)
        if difference > tolerance {
            try? png.write(to: failed)
            Attachment.record(png, named: failed.lastPathComponent)
            Issue.record(
                Comment(rawValue: String(
                    format: "%@ differs from its reference in %.2f%% of pixels; see %@.",
                    name, difference * 100, failed.lastPathComponent
                )),
                sourceLocation: sourceLocation
            )
        }
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

    /// The share of pixels whose channels differ by more than a rounding
    /// step; a size change differs everywhere.
    static func differingFraction(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return 1 }
        let a = rgba(lhs), b = rgba(rhs)
        var differing = 0
        for pixel in stride(from: 0, to: a.count, by: 4) {
            for channel in 0..<4 where abs(Int(a[pixel + channel]) - Int(b[pixel + channel])) > 8 {
                differing += 1
                break
            }
        }
        return Double(differing) / Double(lhs.width * lhs.height)
    }

    private static func rgba(_ image: CGImage) -> [UInt8] {
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

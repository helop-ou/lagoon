import SwiftUI
import Testing
import UIKit

/// See docs/design-system.md, "Snapshot tests".
@MainActor
enum Snapshot {
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
                "Recorded \(reference.lastPathComponent). Look at it, then run again.",
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
            Comment(rawValue: "\(name) \(comparison.summary(actual: image, expected: expected)). See \(files)."),
            sourceLocation: sourceLocation
        )
    }

    /// Not `ImageRenderer`: it leaves `ScrollView` and `NavigationStack`
    /// blank. An iOS `NavigationLink` outside a stack draws as disabled.
    private static func render(_ view: some View, size: CGSize) async -> CGImage? {
        // tvOS overscan insets and iOS scroll-edge blur belong to screens.
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

    struct Comparison {
        let fraction: Double
        let bounds: CGRect?
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
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    marked[pixel] = 255
                    marked[pixel + 1] = 0
                    marked[pixel + 2] = 0
                    marked[pixel + 3] = 255
                } else {
                    // Premultiplied, so dimming colour keeps alpha valid.
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

import Testing
import UIKit
@testable import Lagoon

/// What a failing snapshot reports: how much changed, where, and an image
/// that marks it.
@Suite("Snapshot comparison")
struct SnapshotComparisonTests {
    @Test func aChangeIsMeasuredLocatedAndMarkedRed() throws {
        let reference = try image(width: 10, height: 8)
        let changed = try image(width: 10, height: 8, red: CGRect(x: 4, y: 5, width: 3, height: 2))

        let comparison = Snapshot.compare(changed, with: reference)

        #expect(comparison.fraction == 6.0 / 80)
        #expect(comparison.bounds == CGRect(x: 4, y: 5, width: 3, height: 2))
        let diff = try pixels(#require(comparison.diff))
        #expect(diff[5][4] == [255, 0, 0])
        #expect(diff[6][6] == [255, 0, 0])
        // Unchanged pixels are the reference at a third.
        #expect(diff[0][0] == [0, 0, 255 / 3])
        #expect(diff[5][7] == [0, 0, 255 / 3])
        #expect(comparison.summary(actual: changed, expected: reference)
            == "differs from its reference in 7.50% of pixels, within x 4–6, y 5–6")
    }

    @Test func identicalImagesDifferNowhere() throws {
        let reference = try image(width: 10, height: 8)

        let comparison = Snapshot.compare(try image(width: 10, height: 8), with: reference)

        #expect(comparison.fraction == 0)
        #expect(comparison.bounds == nil)
    }

    @Test func aSizeChangeIsReportedAsOne() throws {
        let reference = try image(width: 10, height: 8)
        let taller = try image(width: 10, height: 9)

        let comparison = Snapshot.compare(taller, with: reference)

        #expect(comparison.fraction == 1)
        #expect(comparison.diff == nil)
        #expect(comparison.summary(actual: taller, expected: reference) == "is 10×9 but its reference is 10×8")
    }

    // MARK: - Fixtures

    /// Blue, with an optional red rectangle measured from the top left.
    private func image(width: Int, height: Int, red: CGRect? = nil) throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: width, height: height)
        return try #require(UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0, green: 0, blue: 1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let red {
                UIColor(red: 1, green: 0, blue: 0, alpha: 1).setFill()
                context.fill(red)
            }
        }.cgImage)
    }

    /// RGB rows, top first.
    private func pixels(_ image: CGImage) -> [[[UInt8]]] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (0..<image.height).map { y in
            (0..<image.width).map { x in
                let pixel = (y * image.width + x) * 4
                return Array(bytes[pixel..<pixel + 3])
            }
        }
    }
}

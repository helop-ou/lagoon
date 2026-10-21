import UIKit

@MainActor
enum Artwork {
    static func landscape(seed: Int) -> UIImage { draw(CGSize(width: 640, height: 360), seed: seed) }
    static func poster(seed: Int) -> UIImage { draw(CGSize(width: 400, height: 600), seed: seed) }

    private static func draw(_ size: CGSize, seed: Int) -> UIImage {
        let hues: [CGFloat] = [0.55, 0.08, 0.33, 0.78, 0.95, 0.15, 0.62, 0.45]
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let top = UIColor(hue: hues[seed % hues.count], saturation: 0.6, brightness: 0.8, alpha: 1)
            let bottom = UIColor(hue: hues[(seed + 3) % hues.count], saturation: 0.7, brightness: 0.35, alpha: 1)
            top.setFill()
            context.fill(CGRect(origin: .zero, size: CGSize(width: size.width, height: size.height / 2)))
            bottom.setFill()
            context.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
            UIColor.white.withAlphaComponent(0.85).setFill()
            let side = min(size.width, size.height) / 3
            context.cgContext.fillEllipse(in: CGRect(
                x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side
            ))
        }
    }
}

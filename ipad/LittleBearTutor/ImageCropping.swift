import CoreGraphics
import UIKit

/// Crop rectangles are kept in normalized image coordinates (0...1, origin top-left) so they
/// are independent of screen size and image resolution.
enum CropMath {
    static let minSide: CGFloat = 0.1

    enum Corner: String, CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: String { rawValue }
        func point(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
            case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
            }
        }
    }

    /// Moves the whole rectangle, keeping its size and staying inside the image.
    static func move(_ rect: CGRect, by delta: CGSize) -> CGRect {
        let x = min(max(0, rect.minX + delta.width), 1 - rect.width)
        let y = min(max(0, rect.minY + delta.height), 1 - rect.height)
        return CGRect(x: x, y: y, width: rect.width, height: rect.height)
    }

    /// Drags one corner; the opposite corner stays fixed. Never smaller than `minSide` or outside the image.
    static func resize(_ rect: CGRect, corner: Corner, by delta: CGSize) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        switch corner {
        case .topLeft: minX += delta.width; minY += delta.height
        case .topRight: maxX += delta.width; minY += delta.height
        case .bottomLeft: minX += delta.width; maxY += delta.height
        case .bottomRight: maxX += delta.width; maxY += delta.height
        }
        minX = min(max(0, minX), rect.maxX - minSide)
        minY = min(max(0, minY), rect.maxY - minSide)
        maxX = max(min(1, maxX), rect.minX + minSide)
        maxY = max(min(1, maxY), rect.minY + minSide)
        switch corner {
        case .topLeft: return CGRect(x: minX, y: minY, width: rect.maxX - minX, height: rect.maxY - minY)
        case .topRight: return CGRect(x: rect.minX, y: minY, width: maxX - rect.minX, height: rect.maxY - minY)
        case .bottomLeft: return CGRect(x: minX, y: rect.minY, width: rect.maxX - minX, height: maxY - rect.minY)
        case .bottomRight: return CGRect(x: rect.minX, y: rect.minY, width: maxX - rect.minX, height: maxY - rect.minY)
        }
    }
}

enum ImageCropper {
    /// Redraws the image so its pixels are upright (camera photos are often stored rotated with an orientation flag).
    static func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }

    /// Crops to a normalized rectangle. Returns nil when the rectangle does not overlap the image.
    static func crop(_ image: UIImage, to normalized: CGRect) -> UIImage? {
        let source = upright(image)
        guard let cg = source.cgImage else { return nil }
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        let pixels = CGRect(x: normalized.minX * full.width, y: normalized.minY * full.height,
                            width: normalized.width * full.width, height: normalized.height * full.height)
            .integral.intersection(full)
        guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let cropped = cg.cropping(to: pixels) else { return nil }
        return UIImage(cgImage: cropped)
    }

    #if DEBUG
    /// A generated worksheet photo so UI tests can exercise cropping and recognition without a camera.
    static func sampleHomework() -> UIImage {
        let size = CGSize(width: 1600, height: 1200)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let style: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black]
            ("口算练习  第 12 页" as NSString).draw(at: CGPoint(x: 120, y: 120), withAttributes: style)
            ("1.  24 + 18 = ____" as NSString).draw(at: CGPoint(x: 120, y: 360), withAttributes: style)
            ("2.  36 + 17 = ____" as NSString).draw(at: CGPoint(x: 120, y: 560), withAttributes: style)
        }
    }
    #endif
}

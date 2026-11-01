import Foundation
import UIKit

struct ImageNormalizer: Sendable {
    var maxDimension: CGFloat = 2048
    var compressionQuality: CGFloat = 0.9

    func normalize(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return normalize(image: image)
    }

    func normalize(image: UIImage) -> Data? {
        let originalSize = image.size
        guard originalSize.width > 0, originalSize.height > 0 else { return nil }
        let scale = min(1, maxDimension / max(originalSize.width, originalSize.height))
        let targetSize = CGSize(width: max(1, originalSize.width * scale), height: max(1, originalSize.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let rendered = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: targetSize))
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return rendered.jpegData(compressionQuality: compressionQuality)
    }
}

/// Produces a consistently framed bottle image while preserving the original
/// cutout's proportions and transparent background.
struct BottleImageNormalizer: Sendable {
    static let canvasSize = CGSize(width: 600, height: 1_000)

    var canvasSize = Self.canvasSize
    var maximumStraighteningAngle = 15.0 * .pi / 180.0
    var alphaThreshold: UInt8 = 18

    func normalize(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        return normalize(image: image)
    }

    func normalizeForDisplay(data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let pixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        if pixelSize == canvasSize {
            return data
        }
        return normalize(image: image)
    }

    func normalize(image: UIImage) -> Data? {
        guard canvasSize.width > 0,
              canvasSize.height > 0,
              let orientedImage = renderWithResolvedOrientation(image),
              let initialMetrics = foregroundMetrics(in: orientedImage) else { return nil }

        let straightenedImage: CGImage
        if initialMetrics.coverage < 0.95,
           initialMetrics.bounds.height > initialMetrics.bounds.width * 1.15 {
            let correction = straighteningCorrection(for: initialMetrics.axisAngle)
            straightenedImage = abs(correction) > 0.005
                ? (rotate(orientedImage, by: correction) ?? orientedImage)
                : orientedImage
        } else {
            straightenedImage = orientedImage
        }

        guard let metrics = foregroundMetrics(in: straightenedImage) else { return nil }
        let imageBounds = CGRect(x: 0, y: 0, width: straightenedImage.width, height: straightenedImage.height)
        let padding = max(2, round(max(metrics.bounds.width, metrics.bounds.height) * 0.012))
        let cropRect = metrics.bounds.insetBy(dx: -padding, dy: -padding)
            .integral
            .intersection(imageBounds)
        guard cropRect.width > 1,
              cropRect.height > 1,
              let croppedImage = straightenedImage.cropping(to: cropRect) else { return nil }

        let horizontalMargin = canvasSize.width * 0.10
        let topMargin = canvasSize.height * 0.05
        let bottomMargin = canvasSize.height * 0.04
        let availableSize = CGSize(
            width: canvasSize.width - horizontalMargin * 2,
            height: canvasSize.height - topMargin - bottomMargin
        )
        let scale = min(
            availableSize.width / CGFloat(croppedImage.width),
            availableSize.height / CGFloat(croppedImage.height)
        )
        let drawSize = CGSize(
            width: CGFloat(croppedImage.width) * scale,
            height: CGFloat(croppedImage.height) * scale
        )
        let drawOrigin = CGPoint(
            x: (canvasSize.width - drawSize.width) / 2,
            y: canvasSize.height - bottomMargin - drawSize.height
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        return renderer.image { _ in
            UIImage(cgImage: croppedImage).draw(in: CGRect(origin: drawOrigin, size: drawSize))
        }.pngData()
    }

    private func renderWithResolvedOrientation(_ image: UIImage) -> CGImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.cgImage
    }

    private func straighteningCorrection(for axisAngle: Double) -> Double {
        var correction = (.pi / 2) - axisAngle
        while correction > .pi / 2 { correction -= .pi }
        while correction < -.pi / 2 { correction += .pi }
        return min(maximumStraighteningAngle, max(-maximumStraighteningAngle, correction))
    }

    private func rotate(_ image: CGImage, by angle: Double) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let cosine = abs(cos(angle))
        let sine = abs(sin(angle))
        let rotatedSize = CGSize(
            width: ceil(width * cosine + height * sine),
            height: ceil(width * sine + height * cosine)
        )
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: rotatedSize, format: format).image { context in
            context.cgContext.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
            context.cgContext.rotate(by: angle)
            UIImage(cgImage: image).draw(in: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
        }.cgImage
    }

    private func foregroundMetrics(in image: CGImage) -> ForegroundMetrics? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return nil }

        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var count = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var sumXX = 0.0
        var sumYY = 0.0
        var sumXY = 0.0

        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > alphaThreshold {
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                let doubleX = Double(x)
                let doubleY = Double(y)
                count += 1
                sumX += doubleX
                sumY += doubleY
                sumXX += doubleX * doubleX
                sumYY += doubleY * doubleY
                sumXY += doubleX * doubleY
            }
        }
        guard count > 0, maxX >= minX, maxY >= minY else { return nil }

        let meanX = sumX / count
        let meanY = sumY / count
        let covarianceXX = sumXX / count - meanX * meanX
        let covarianceYY = sumYY / count - meanY * meanY
        let covarianceXY = sumXY / count - meanX * meanY
        let axisAngle = 0.5 * atan2(2 * covarianceXY, covarianceXX - covarianceYY)
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        return ForegroundMetrics(
            bounds: bounds,
            coverage: count / Double(width * height),
            axisAngle: axisAngle
        )
    }

    private struct ForegroundMetrics {
        let bounds: CGRect
        let coverage: Double
        let axisAngle: Double
    }
}

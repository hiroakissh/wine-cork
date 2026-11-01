import CoreImage
import CoreVideo
import UIKit
import Vision

struct VisionBottleSegmenter: BottleSegmenter {
    func segment(image: CGImage) async throws -> SegmentationResult {
        try Task.checkCancellation()
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScanError.segmentationUnavailable
        }
        guard let observation = request.results?.first else { throw ScanError.segmentationUnavailable }
        let highResolutionMask = try? observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )
        let isolatedImageData = (try? observation.generateMaskedImage(
            ofInstances: observation.allInstances,
            from: handler,
            croppedToInstancesExtent: false
        )).flatMap(Self.pngData(from:))
        if let measured = Self.measure(mask: highResolutionMask ?? observation.instanceMask) {
            let bounds = measured.boundingBox.insetBy(dx: -0.02, dy: -0.02)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let confidence = min(1, max(0.15, measured.areaRatio * 3))
            let shapeFeatures = highResolutionMask.flatMap {
                BottleShapeFeatureExtractor.extract(mask: $0)
            }
            return SegmentationResult(
                boundingBox: bounds,
                confidence: confidence,
                maskAreaRatio: measured.areaRatio,
                shapeFeatures: shapeFeatures,
                isolatedImageData: isolatedImageData
            )
        }

        // A valid foreground result without a readable pixel mask should still
        // allow registration to continue through the manual editor.
        let fallback = CGRect(x: 0.08, y: 0.04, width: 0.84, height: 0.92)
        return SegmentationResult(
            boundingBox: fallback,
            confidence: 0.15,
            maskAreaRatio: fallback.width * fallback.height
        )
    }

    private static func measure(mask: CVPixelBuffer) -> (boundingBox: CGRect, areaRatio: Double)? {
        let width = CVPixelBufferGetWidth(mask)
        let height = CVPixelBufferGetHeight(mask)
        guard width > 0, height > 0, CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        var foregroundCount = 0

        let pixelFormat = CVPixelBufferGetPixelFormatType(mask)
        for y in 0..<height {
            let rowAddress = baseAddress.advanced(by: y * bytesPerRow)
            for x in 0..<width {
                let isForeground: Bool
                switch pixelFormat {
                case kCVPixelFormatType_OneComponent32Float:
                    isForeground = rowAddress.assumingMemoryBound(to: Float.self)[x] > 0.15
                default:
                    isForeground = rowAddress.assumingMemoryBound(to: UInt8.self)[x] > 0
                }
                if isForeground {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                    foregroundCount += 1
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let boundingBox = CGRect(
            x: Double(minX) / Double(width),
            y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height)
        )
        return (boundingBox, Double(foregroundCount) / Double(width * height))
    }

    private static func pngData(from pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }
}

enum BottleShapeFeatureExtractor {
    static func extract(mask: CVPixelBuffer) -> BottleShapeFeatures? {
        guard let silhouette = Silhouette(mask: mask) else { return nil }
        return silhouette.features
    }

    static func extract(subjectImage: CGImage) -> BottleShapeFeatures? {
        guard subjectImage.alphaInfo != .none,
              let context = CGContext(
                  data: nil,
                  width: subjectImage.width,
                  height: subjectImage.height,
                  bitsPerComponent: 8,
                  bytesPerRow: subjectImage.width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.draw(subjectImage, in: CGRect(x: 0, y: 0, width: subjectImage.width, height: subjectImage.height))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let rowStride = subjectImage.width * 4
        var rows: [Int] = []
        rows.reserveCapacity(subjectImage.height)

        for y in 0..<subjectImage.height {
            let row = bytes.advanced(by: y * rowStride)
            var minX = subjectImage.width
            var maxX = -1
            for x in 0..<subjectImage.width where row[x * 4 + 3] > 18 {
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
            rows.append(maxX >= minX ? maxX - minX + 1 : 0)
        }
        return Silhouette(width: subjectImage.width, height: subjectImage.height, rowWidths: rows)?.features
    }

    private struct Silhouette {
        let width: Int
        let height: Int
        let rowWidths: [Int]

        init?(mask: CVPixelBuffer) {
            let width = CVPixelBufferGetWidth(mask)
            let height = CVPixelBufferGetHeight(mask)
            guard width > 0, height > 0,
                  CVPixelBufferLockBaseAddress(mask, .readOnly) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(mask, .readOnly) }
            guard let baseAddress = CVPixelBufferGetBaseAddress(mask) else { return nil }

            let bytesPerRow = CVPixelBufferGetBytesPerRow(mask)
            let pixelFormat = CVPixelBufferGetPixelFormatType(mask)
            var rowWidths: [Int] = []
            rowWidths.reserveCapacity(height)

            for y in 0..<height {
                let rowAddress = baseAddress.advanced(by: y * bytesPerRow)
                var minX = width
                var maxX = -1
                for x in 0..<width {
                    let isForeground: Bool
                    switch pixelFormat {
                    case kCVPixelFormatType_OneComponent32Float:
                        isForeground = rowAddress.assumingMemoryBound(to: Float.self)[x] > 0.12
                    default:
                        isForeground = rowAddress.assumingMemoryBound(to: UInt8.self)[x] > 18
                    }
                    if isForeground {
                        minX = min(minX, x)
                        maxX = max(maxX, x)
                    }
                }
                rowWidths.append(maxX >= minX ? maxX - minX + 1 : 0)
            }
            self.init(width: width, height: height, rowWidths: rowWidths)
        }

        init?(width: Int, height: Int, rowWidths: [Int]) {
            guard width > 0, height > 0, rowWidths.count == height else { return nil }
            self.width = width
            self.height = height
            self.rowWidths = rowWidths
            guard rowWidths.max() ?? 0 > 0 else { return nil }
        }

        var features: BottleShapeFeatures {
            let maxWidth = Double(rowWidths.max() ?? 1)
            let nonEmptyRows = rowWidths.enumerated().filter { $0.element > 0 }
            let top = nonEmptyRows.first?.offset ?? 0
            let bottom = nonEmptyRows.last?.offset ?? max(top, height - 1)
            let silhouetteHeight = max(1, bottom - top + 1)
            let aspectRatio = Double(silhouetteHeight) / maxWidth
            let shoulderRow = rowWidths.enumerated()
                .first { $0.offset >= top && Double($0.element) >= maxWidth * 0.82 }?.offset ?? top
            let narrowLimit = maxWidth * 0.55
            var neckRows = 0
            for index in top...bottom {
                if Double(rowWidths[index]) <= narrowLimit {
                    neckRows += 1
                } else {
                    break
                }
            }
            let weightedCenter = rowWidths.enumerated().reduce(0.0) { partial, element in
                partial + Double(max(0, element.element)) * Double(element.offset - top)
            }
            let totalWidth = max(1, rowWidths.reduce(0, +))
            let bodyWidthPosition = min(1, max(0, weightedCenter / Double(totalWidth) / Double(silhouetteHeight)))
            return BottleShapeFeatures(
                aspectRatio: aspectRatio,
                shoulderHeight: Double(shoulderRow - top) / Double(silhouetteHeight),
                neckLength: Double(neckRows) / Double(silhouetteHeight),
                bodyWidthPosition: bodyWidthPosition,
                sparklingLikelihood: 0
            )
        }
    }
}

struct VisionLabelDetector {
    func detect(image: CGImage) throws -> Quadrilateral {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 8
        request.minimumSize = 0.05
        request.minimumConfidence = 0.2
        request.minimumAspectRatio = 0.25
        request.maximumAspectRatio = 1
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScanError.labelNotFound
        }

        let candidates = (request.results ?? []).filter { observation in
            let box = observation.boundingBox
            return box.width < 0.9 && box.height < 0.65 && box.width * box.height > 0.02
        }
        guard let observation = candidates.max(by: { score($0) < score($1) }) else {
            throw ScanError.labelNotFound
        }
        let quad = Quadrilateral(
            topLeft: convert(observation.topLeft),
            topRight: convert(observation.topRight),
            bottomLeft: convert(observation.bottomLeft),
            bottomRight: convert(observation.bottomRight)
        )
        guard quad.isValid else { throw ScanError.labelGeometryInvalid }
        return quad
    }

    private func score(_ observation: VNRectangleObservation) -> Double {
        let box = observation.boundingBox
        let centerX = abs(box.midX - 0.5)
        let centerY = abs(box.midY - 0.55)
        let centeredness = (1 - min(1, centerX * 2)) * (1 - min(1, centerY))
        return Double(box.width * box.height) * centeredness * Double(observation.confidence)
    }

    private func convert(_ point: CGPoint) -> CGPoint {
        // Vision uses a lower-left origin; QuadEditorView uses a top-left origin.
        CGPoint(x: point.x, y: 1 - point.y)
    }
}

struct VisionTextRecognizer: TextRecognizer {
    var recognitionLanguages: [String] = ["ja-JP", "en-US", "fr-FR", "it-IT", "de-DE"]

    func recognize(image: CGImage) async throws -> OCRResult {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScanError.ocrFailed
        }
        let observations = (request.results ?? []).compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRObservation(text: candidate.string, confidence: Double(candidate.confidence), boundingBox: observation.boundingBox)
        }
        guard !observations.isEmpty else { throw ScanError.ocrFailed }
        return OCRResult(observations: observations)
    }
}

struct LabelPerspectiveCorrector {
    func correct(image: CIImage, quadrilateral: Quadrilateral) throws -> CIImage {
        guard quadrilateral.isValid else { throw ScanError.labelGeometryInvalid }
        let extent = image.extent
        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(CIVector(cgPoint: convert(quadrilateral.topLeft, in: extent)), forKey: "inputTopLeft")
        filter?.setValue(CIVector(cgPoint: convert(quadrilateral.topRight, in: extent)), forKey: "inputTopRight")
        filter?.setValue(CIVector(cgPoint: convert(quadrilateral.bottomLeft, in: extent)), forKey: "inputBottomLeft")
        filter?.setValue(CIVector(cgPoint: convert(quadrilateral.bottomRight, in: extent)), forKey: "inputBottomRight")
        guard let output = filter?.outputImage else { throw ScanError.labelGeometryInvalid }
        return output
    }

    private func convert(_ point: CGPoint, in extent: CGRect) -> CGPoint {
        CGPoint(x: extent.minX + point.x * extent.width, y: extent.minY + (1 - point.y) * extent.height)
    }
}

enum BottleTemplateCatalog {
    static let templateIDs: [BottleShape: String] = [
        .bordeaux: "bordeaux-v1",
        .burgundy: "burgundy-v1",
        .rhone: "rhone-v1",
        .alsace: "alsace-v1",
        .champagne: "champagne-v1",
        .generic: "generic-v1"
    ]

    static func templateID(for shape: BottleShape) -> String { templateIDs[shape] ?? "generic-v1" }
}

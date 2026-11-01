import CoreGraphics
import Foundation

struct NormalizedImage: Sendable {
    let data: Data
    let pixelWidth: Int
    let pixelHeight: Int
}

struct SegmentationResult: Equatable, Sendable {
    let boundingBox: CGRect
    let confidence: Double
    let maskAreaRatio: Double
    let shapeFeatures: BottleShapeFeatures?
    let isolatedImageData: Data?

    init(
        boundingBox: CGRect,
        confidence: Double,
        maskAreaRatio: Double,
        shapeFeatures: BottleShapeFeatures? = nil,
        isolatedImageData: Data? = nil
    ) {
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.maskAreaRatio = maskAreaRatio
        self.shapeFeatures = shapeFeatures
        self.isolatedImageData = isolatedImageData
    }
}

struct Quadrilateral: Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomLeft: CGPoint
    var bottomRight: CGPoint

    var isValid: Bool {
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        let area = abs(points.enumerated().reduce(0.0) { partial, item in
            let next = points[(item.offset + 1) % points.count]
            return partial + (item.element.x * next.y) - (next.x * item.element.y)
        }) / 2
        return area > 0.001
    }
}

struct OCRObservation: Equatable, Sendable {
    let text: String
    let confidence: Double
    let boundingBox: CGRect
}

struct OCRResult: Equatable, Sendable {
    let observations: [OCRObservation]

    var rawText: String { observations.map(\.text).joined(separator: "\n") }
    var topCandidate: String? { observations.max(by: { $0.confidence < $1.confidence })?.text }

    var observationsArchiveData: Data? {
        let snapshots = observations.map {
            OCRObservationSnapshot(
                text: $0.text,
                confidence: $0.confidence,
                minX: $0.boundingBox.minX,
                minY: $0.boundingBox.minY,
                width: $0.boundingBox.width,
                height: $0.boundingBox.height
            )
        }
        return try? JSONEncoder().encode(snapshots)
    }
}

struct OCRObservationSnapshot: Codable, Equatable, Sendable {
    let text: String
    let confidence: Double
    let minX: Double
    let minY: Double
    let width: Double
    let height: Double
}

struct OCRMetadataCandidate: Equatable, Sendable {
    let probableName: String?
    let probableProducer: String?
    let probableRegion: String?
    let probableCountry: String?
    let vintage: Int?
    let volumeML: Int?
    let alcoholPercent: Double?
    let grapeVarieties: [String]
    let wineType: WineType?
}

struct RuleBasedOCRMetadataParser: Sendable {
    private let knownGrapes: [(canonical: String, aliases: [String])] = [
        ("Cabernet Sauvignon", ["cabernet sauvignon", "カベルネ・ソーヴィニヨン", "カベルネソーヴィニヨン"]),
        ("Merlot", ["merlot", "メルロー"]),
        ("Pinot Noir", ["pinot noir", "ピノ・ノワール", "ピノノワール"]),
        ("Chardonnay", ["chardonnay", "シャルドネ"]),
        ("Syrah", ["syrah", "シラー", "shiraz", "シラーズ"]),
        ("Riesling", ["riesling", "リースリング"]),
        ("Sauvignon Blanc", ["sauvignon blanc", "ソーヴィニヨン・ブラン", "ソーヴィニヨンブラン"]),
        ("Pinot Gris", ["pinot gris", "ピノ・グリ", "ピノグリ"]),
        ("Gamay", ["gamay", "ガメイ"]),
        ("Nebbiolo", ["nebbiolo", "ネッビオーロ"]),
        ("Sangiovese", ["sangiovese", "サンジョヴェーゼ"]),
        ("Tempranillo", ["tempranillo", "テンプラニーリョ"])
    ]

    func parse(_ result: OCRResult) -> OCRMetadataCandidate {
        let lines = result.observations.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let combined = lines.joined(separator: " ")
        let folded = combined.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let vintage = firstCapture(#"(?<!\d)((?:19|20)\d{2})(?!\d)"#, in: combined).flatMap(Int.init)
        let volumeML: Int? = {
            guard let match = firstMatch(#"(?<!\d)(\d{2,4})\s*(mL|ml|cL|cl)(?![a-z])"#, in: combined),
                  let value = Double(match.value), let unit = match.unit?.lowercased() else { return nil }
            return Int(unit == "cl" ? value * 10 : value)
        }()
        let alcohol = firstCapture(#"(?<!\d)(\d{1,2}(?:[\.,]\d)?)\s*%"#, in: combined)
            .flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }

        let grapes = knownGrapes.compactMap { grape in
            grape.aliases.contains { folded.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) }
                ? grape.canonical : nil
        }
        let wineType: WineType? = {
            if folded.contains("sparkling") || folded.contains("champagne") || combined.contains("スパークリング") || combined.contains("シャンパーニュ") { return .sparkling }
            if folded.contains("rosé") || folded.contains("rose") || combined.contains("ロゼ") { return .rose }
            if folded.contains("white") || combined.contains("白ワイン") || combined.contains("白") { return .white }
            if folded.contains("red") || combined.contains("赤ワイン") || combined.contains("赤") { return .red }
            return nil
        }()

        let excludedWords = ["wine", "vino", "vin", "ワイン", "ml", "%", "alcohol", "アルコール", "赤", "白", "ロゼ"]
        let probableProducer = valueAfterPrefix(in: lines, prefixes: ["producer", "winery", "生産者", "醸造元"])
        let probableRegion = valueAfterPrefix(in: lines, prefixes: ["region", "appellation", "産地", "地域"])
        let probableCountry = valueAfterPrefix(in: lines, prefixes: ["country", "origin", "原産国", "国"])
        let probableName = lines.first { line in
            guard line.count >= 3, line.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
            let normalized = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let looksLikeField = probableProducer == line || probableRegion == line || probableCountry == line
            return !looksLikeField && !excludedWords.contains(where: { normalized == $0 || normalized.hasPrefix($0 + " ") })
        }

        return OCRMetadataCandidate(
            probableName: probableName,
            probableProducer: probableProducer,
            probableRegion: probableRegion,
            probableCountry: probableCountry,
            vintage: vintage,
            volumeML: volumeML,
            alcoholPercent: alcohol,
            grapeVarieties: grapes,
            wineType: wineType
        )
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        firstMatch(pattern, in: text)?.value
    }

    private func valueAfterPrefix(in lines: [String], prefixes: [String]) -> String? {
        for line in lines {
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { continue }
            let key = String(line[..<separator]).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            let normalizedPrefixes = prefixes.map { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
            guard normalizedPrefixes.contains(where: { key == $0 }) else { continue }
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func firstMatch(_ pattern: String, in text: String) -> (value: String, unit: String?)? {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let valueRange = Range(match.range(at: 1), in: text) else { return nil }
        let value = String(text[valueRange])
        var unit: String?
        if match.numberOfRanges > 2, let unitRange = Range(match.range(at: 2), in: text) {
            unit = String(text[unitRange])
        }
        return (value, unit)
    }
}

struct BottleShapeFeatures: Equatable, Sendable {
    let aspectRatio: Double
    let shoulderHeight: Double
    let neckLength: Double
    let bodyWidthPosition: Double
    let sparklingLikelihood: Double
}

struct BottleShapeCandidate: Equatable, Sendable {
    let shape: BottleShape
    let confidence: Double
}

enum ScanError: Error, Equatable, LocalizedError {
    case invalidImage
    case imageTooSmall
    case segmentationUnavailable
    case segmentationLowConfidence
    case labelNotFound
    case labelGeometryInvalid
    case ocrUnavailable
    case ocrFailed
    case cancelled
    case renderingFailed
    case storageFailed

    var errorDescription: String? {
        switch self {
        case .invalidImage: "画像を読み込めませんでした。"
        case .imageTooSmall: "画像の解像度が不足しています。"
        case .segmentationUnavailable: "ボトル抽出を利用できません。"
        case .segmentationLowConfidence: "ボトルの範囲を確認してください。"
        case .labelNotFound: "ラベルを検出できませんでした。"
        case .labelGeometryInvalid: "ラベルの四隅を確認してください。"
        case .ocrUnavailable: "文字認識を利用できません。"
        case .ocrFailed: "文字を認識できませんでした。手入力を続けられます。"
        case .cancelled: "処理をキャンセルしました。"
        case .renderingFailed: "3D表示を作成できませんでした。"
        case .storageFailed: "データを保存できませんでした。"
        }
    }
}

protocol BottleSegmenter: Sendable {
    func segment(image: CGImage) async throws -> SegmentationResult
}

protocol TextRecognizer: Sendable {
    func recognize(image: CGImage) async throws -> OCRResult
}

protocol BottleShapeClassifier: Sendable {
    func classify(features: BottleShapeFeatures) -> [BottleShapeCandidate]
}

struct RuleBasedBottleShapeClassifier: BottleShapeClassifier {
    func classify(features: BottleShapeFeatures) -> [BottleShapeCandidate] {
        let scores: [(BottleShape, Double)] = [
            (.bordeaux, scoreBordeaux(features)),
            (.burgundy, scoreBurgundy(features)),
            (.rhone, scoreRhone(features)),
            (.alsace, scoreAlsace(features)),
            (.champagne, min(1, features.sparklingLikelihood)),
            (.generic, 0.25)
        ]
        let total = max(scores.map(\.1).reduce(0, +), 1)
        return scores
            .map { BottleShapeCandidate(shape: $0.0, confidence: min(1, $0.1 / total * 2.2)) }
            .sorted { $0.confidence > $1.confidence }
    }

    private func scoreBordeaux(_ f: BottleShapeFeatures) -> Double {
        closeness(f.aspectRatio, target: 3.3, tolerance: 1.0) * 0.45 + closeness(f.shoulderHeight, target: 0.25, tolerance: 0.3) * 0.55
    }

    private func scoreBurgundy(_ f: BottleShapeFeatures) -> Double {
        closeness(f.aspectRatio, target: 3.0, tolerance: 1.0) * 0.4 + closeness(f.shoulderHeight, target: 0.1, tolerance: 0.25) * 0.6
    }

    private func scoreRhone(_ f: BottleShapeFeatures) -> Double {
        closeness(f.aspectRatio, target: 3.5, tolerance: 1.0) * 0.5 + closeness(f.neckLength, target: 0.28, tolerance: 0.3) * 0.5
    }

    private func scoreAlsace(_ f: BottleShapeFeatures) -> Double {
        closeness(f.aspectRatio, target: 4.5, tolerance: 1.4) * 0.7 + closeness(f.bodyWidthPosition, target: 0.55, tolerance: 0.3) * 0.3
    }

    private func closeness(_ value: Double, target: Double, tolerance: Double) -> Double {
        max(0, 1 - abs(value - target) / tolerance)
    }
}

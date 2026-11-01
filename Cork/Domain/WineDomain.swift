import Foundation

enum WineType: String, CaseIterable, Codable, Identifiable, Sendable {
    case red
    case white
    case rose
    case sparkling
    case dessert
    case fortified
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .red: "赤"
        case .white: "白"
        case .rose: "ロゼ"
        case .sparkling: "スパークリング"
        case .dessert: "デザート"
        case .fortified: "酒精強化"
        case .other: "その他"
        }
    }
}

enum BottleShape: String, CaseIterable, Codable, Identifiable, Sendable {
    case bordeaux
    case burgundy
    case rhone
    case alsace
    case champagne
    case generic

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bordeaux: "ボルドー"
        case .burgundy: "ブルゴーニュ"
        case .rhone: "ローヌ"
        case .alsace: "アルザス"
        case .champagne: "シャンパーニュ"
        case .generic: "その他"
        }
    }
}

enum BottleLifecycleState: String, CaseIterable, Codable, Identifiable, Sendable {
    case owned
    case opened
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .owned: "所持"
        case .opened: "開栓中"
        case .finished: "飲了"
        }
    }

    var systemImage: String {
        switch self {
        case .owned: "shippingbox"
        case .opened: "wineglass"
        case .finished: "checkmark.circle"
        }
    }
}

struct CellarEntry: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let cellarID: UUID
    let wineID: UUID
    var displayName: String
    var producer: String?
    var region: String?
    var country: String?
    var grapeVarieties: [String]
    var vintage: Int?
    var wineType: WineType
    var volumeML: Int?
    var alcoholPercent: Double?
    var ocrRawText: String?
    var ocrObservationsData: Data?
    var lifecycleState: BottleLifecycleState
    var storageLocation: String?
    var acquiredAt: Date?
    var openedAt: Date?
    var finishedAt: Date?
    var remainingPercent: Int?
    var purchasePrice: Double?
    var sourceImageAssetID: UUID?
    var labelImageAssetID: UUID?
    var thumbnailAssetID: UUID?
    var bottleShape: BottleShape
    var templateID: String?
    var bottle3DAssetID: UUID?
    var tastingCount: Int
    var lastTastedAt: Date?
    var ratingSummary: Double?
    var tags: [String]
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int
}

struct TastingDraft: Sendable {
    var rating: Int?
    var acidity: Int?
    var sweetness: Int?
    var tannin: Int?
    var body: Int?
    var alcohol: Int?
    var finish: Int?
    var aromaTags: [String]
    var palateTags: [String]
    var note: String?
    var tastedAt: Date
    var servingTemperatureCelsius: Double?
    var openedHoursBeforeTasting: Double?
}

struct PairingDraft: Sendable {
    var dishName: String
    var dishCategory: String?
    var score: Int
    var note: String?
}

struct TasteProfile: Equatable, Sendable {
    var tastingCount: Int
    var averageAcidity: Double?
    var averageSweetness: Double?
    var averageTannin: Double?
    var averageBody: Double?
    var varianceAcidity: Double?
    var varianceSweetness: Double?
    var varianceTannin: Double?
    var varianceBody: Double?
    var favoriteTags: [String]
    var pairingCategories: [PairingCategorySummary]

    var hasEnoughData: Bool { tastingCount >= 3 }
}

struct PairingCategorySummary: Equatable, Sendable, Identifiable {
    let category: String
    let averageScore: Double
    let count: Int

    var id: String { category }
}

enum CellarSort: String, CaseIterable, Identifiable {
    case updated
    case name
    case vintage
    case rating

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .updated: "更新日"
        case .name: "名称"
        case .vintage: "ヴィンテージ"
        case .rating: "評価"
        }
    }
}

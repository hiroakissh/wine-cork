import Foundation

struct CorkArchive: Codable, Sendable {
    static let format = "com.hiroaki.cork.cellar"
    static let currentSchemaVersion = 1

    let format: String
    let schemaVersion: Int
    let exportedAt: Date
    let cellars: [CellarArchiveCellar]
    let wines: [CellarArchiveWine]
    let bottles: [CellarArchiveBottle]
    let tastings: [CellarArchiveTasting]
    let pairings: [CellarArchivePairing]
    let mediaAssets: [CellarArchiveMediaAsset]
    let bottle3DAssets: [CellarArchiveBottle3DAsset]
    let lifecycleEvents: [CellarArchiveLifecycleEvent]

    init(
        cellars: [CellarArchiveCellar],
        wines: [CellarArchiveWine],
        bottles: [CellarArchiveBottle],
        tastings: [CellarArchiveTasting],
        pairings: [CellarArchivePairing],
        mediaAssets: [CellarArchiveMediaAsset],
        bottle3DAssets: [CellarArchiveBottle3DAsset],
        lifecycleEvents: [CellarArchiveLifecycleEvent],
        exportedAt: Date = .now
    ) {
        self.format = Self.format
        self.schemaVersion = Self.currentSchemaVersion
        self.exportedAt = exportedAt
        self.cellars = cellars
        self.wines = wines
        self.bottles = bottles
        self.tastings = tastings
        self.pairings = pairings
        self.mediaAssets = mediaAssets
        self.bottle3DAssets = bottle3DAssets
        self.lifecycleEvents = lifecycleEvents
    }

    func validate() throws {
        guard format == Self.format else { throw CorkArchiveError.unsupportedFormat }
        guard schemaVersion <= Self.currentSchemaVersion else { throw CorkArchiveError.unsupportedSchemaVersion }

        let cellarIDs = Set(cellars.map(\.id))
        let wineIDs = Set(wines.map(\.id))
        let bottleIDs = Set(bottles.map(\.id))
        let tastingIDs = Set(tastings.map(\.id))
        let mediaIDs = Set(mediaAssets.map(\.id))
        let bottle3DIDs = Set(bottle3DAssets.map(\.id))
        guard cellarIDs.count == cellars.count,
              wineIDs.count == wines.count,
              bottleIDs.count == bottles.count,
              tastingIDs.count == tastings.count,
              mediaIDs.count == mediaAssets.count,
              bottle3DIDs.count == bottle3DAssets.count else {
            throw CorkArchiveError.duplicateIdentifiers
        }
        guard bottles.allSatisfy({ cellarIDs.contains($0.cellarID) && wineIDs.contains($0.wineID) }) else {
            throw CorkArchiveError.brokenReference
        }
        guard tastings.allSatisfy({ bottleIDs.contains($0.bottleID) }) else {
            throw CorkArchiveError.brokenReference
        }
        guard pairings.allSatisfy({ bottleIDs.contains($0.bottleID) }) else {
            throw CorkArchiveError.brokenReference
        }
        guard pairings.allSatisfy({ pairing in
            guard let tastingID = pairing.tastingID else { return true }
            return tastingIDs.contains(tastingID)
        }) else {
            throw CorkArchiveError.brokenReference
        }
        guard bottles.allSatisfy({ bottle in
            let sourceIsValid = bottle.sourceImageAssetID.map(mediaIDs.contains) ?? true
            let labelIsValid = bottle.labelImageAssetID.map(mediaIDs.contains) ?? true
            let thumbnailIsValid = bottle.thumbnailAssetID.map(mediaIDs.contains) ?? true
            let bottle3DIsValid = bottle.bottle3DAssetID.map(bottle3DIDs.contains) ?? true
            return sourceIsValid && labelIsValid && thumbnailIsValid && bottle3DIsValid
        }) else {
            throw CorkArchiveError.brokenReference
        }
        guard lifecycleEvents.allSatisfy({ bottleIDs.contains($0.bottleID) }) else {
            throw CorkArchiveError.brokenReference
        }
    }
}

struct CellarArchiveCellar: Codable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let updatedAt: Date
    let schemaVersion: Int
}

struct CellarArchiveWine: Codable, Sendable {
    let id: UUID
    let name: String
    let producer: String?
    let winery: String?
    let vintage: Int?
    let region: String?
    let country: String?
    let grapeVarieties: [String]
    let wineType: WineType
    let volumeML: Int?
    let alcoholPercent: Double?
    let ocrRawText: String?
    let ocrObservationsData: Data?
    let createdAt: Date
    let updatedAt: Date
    let schemaVersion: Int

    init(id: UUID, name: String, producer: String?, winery: String?, vintage: Int?, region: String?, country: String?, grapeVarieties: [String], wineType: WineType, volumeML: Int?, alcoholPercent: Double?, ocrRawText: String? = nil, ocrObservationsData: Data? = nil, createdAt: Date, updatedAt: Date, schemaVersion: Int) {
        self.id = id
        self.name = name
        self.producer = producer
        self.winery = winery
        self.vintage = vintage
        self.region = region
        self.country = country
        self.grapeVarieties = grapeVarieties
        self.wineType = wineType
        self.volumeML = volumeML
        self.alcoholPercent = alcoholPercent
        self.ocrRawText = ocrRawText
        self.ocrObservationsData = ocrObservationsData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, producer, winery, vintage, region, country, grapeVarieties, wineType, volumeML, alcoholPercent, ocrRawText, ocrObservationsData, createdAt, updatedAt, schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        producer = try container.decodeIfPresent(String.self, forKey: .producer)
        winery = try container.decodeIfPresent(String.self, forKey: .winery)
        vintage = try container.decodeIfPresent(Int.self, forKey: .vintage)
        region = try container.decodeIfPresent(String.self, forKey: .region)
        country = try container.decodeIfPresent(String.self, forKey: .country)
        grapeVarieties = try container.decode([String].self, forKey: .grapeVarieties)
        wineType = try container.decode(WineType.self, forKey: .wineType)
        volumeML = try container.decodeIfPresent(Int.self, forKey: .volumeML)
        alcoholPercent = try container.decodeIfPresent(Double.self, forKey: .alcoholPercent)
        ocrRawText = try container.decodeIfPresent(String.self, forKey: .ocrRawText)
        ocrObservationsData = try container.decodeIfPresent(Data.self, forKey: .ocrObservationsData)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    }
}

struct CellarArchiveBottle: Codable, Sendable {
    let id: UUID
    let cellarID: UUID
    let wineID: UUID
    let lifecycleState: BottleLifecycleState
    let acquiredAt: Date?
    let openedAt: Date?
    let finishedAt: Date?
    let remainingPercent: Int?
    let storageLocation: String?
    let purchasePrice: Double?
    let sourceImageAssetID: UUID?
    let labelImageAssetID: UUID?
    let thumbnailAssetID: UUID?
    let bottleShape: BottleShape
    let templateID: String?
    let bottle3DAssetID: UUID?
    let tastingCount: Int
    let lastTastedAt: Date?
    let ratingSummary: Double?
    let tags: [String]
    let note: String?
    let createdAt: Date
    let updatedAt: Date
    let schemaVersion: Int
}

struct CellarArchiveTasting: Codable, Sendable {
    let id: UUID
    let bottleID: UUID
    let tastedAt: Date
    let rating: Int?
    let acidity: Int?
    let sweetness: Int?
    let tannin: Int?
    let body: Int?
    let alcohol: Int?
    let finish: Int?
    let aromaTags: [String]
    let palateTags: [String]
    let note: String?
    let servingTemperatureCelsius: Double?
    let openedHoursBeforeTasting: Double?
}

struct CellarArchivePairing: Codable, Sendable {
    let id: UUID
    let tastingID: UUID?
    let bottleID: UUID
    let dishName: String
    let dishCategory: String?
    let score: Int
    let note: String?
}

struct CellarArchiveMediaAsset: Codable, Sendable {
    let id: UUID
    let kindRawValue: String
    let byteCount: Int64
    let createdAt: Date
    let checksum: String?
    let data: Data
}

struct CellarArchiveBottle3DAsset: Codable, Sendable {
    let id: UUID
    let templateID: String
    let templateVersion: String
    let textureAssetID: UUID?
    let sourceRawValue: String
    let generatedAt: Date
    let qualityRawValue: String
}

struct CellarArchiveLifecycleEvent: Codable, Sendable {
    let id: UUID
    let bottleID: UUID
    let fromState: BottleLifecycleState?
    let toState: BottleLifecycleState
    let occurredAt: Date
    let note: String?
}

struct CorkArchiveImportResult: Sendable {
    let cellarsInserted: Int
    let winesInserted: Int
    let bottlesInserted: Int
    let tastingsInserted: Int
    let pairingsInserted: Int
    let mediaAssetsInserted: Int
    let bottle3DAssetsInserted: Int
    let lifecycleEventsInserted: Int

    var totalInserted: Int {
        cellarsInserted + winesInserted + bottlesInserted + tastingsInserted + pairingsInserted + mediaAssetsInserted + bottle3DAssetsInserted + lifecycleEventsInserted
    }
}

enum CorkArchiveError: Error, LocalizedError, Equatable {
    case unsupportedFormat
    case unsupportedSchemaVersion
    case duplicateIdentifiers
    case brokenReference
    case invalidMediaKind
    case archiveTooLarge

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Corkのバックアップ形式ではありません。"
        case .unsupportedSchemaVersion: "このアプリでは対応していないバックアップ形式です。"
        case .duplicateIdentifiers: "バックアップ内に重複したデータがあります。"
        case .brokenReference: "バックアップ内の関連データが壊れています。"
        case .invalidMediaKind: "画像データの種類を判別できません。"
        case .archiveTooLarge: "バックアップのサイズが大きすぎます。"
        }
    }
}

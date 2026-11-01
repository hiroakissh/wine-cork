import Foundation
import SwiftData

@Model
final class LocalCellarRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now, schemaVersion: Int = 1) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }
}

@Model
final class WineRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var producer: String?
    var winery: String?
    var vintage: Int?
    var region: String?
    var country: String?
    var grapeVarietiesText: String
    var wineTypeRawValue: String
    var volumeML: Int?
    var alcoholPercent: Double?
    var ocrRawText: String?
    var ocrObservationsData: Data?
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        name: String,
        producer: String? = nil,
        winery: String? = nil,
        vintage: Int? = nil,
        region: String? = nil,
        country: String? = nil,
        grapeVarieties: [String] = [],
        wineType: WineType = .red,
        volumeML: Int? = 750,
        alcoholPercent: Double? = nil,
        ocrRawText: String? = nil,
        ocrObservationsData: Data? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.name = name
        self.producer = producer
        self.winery = winery
        self.vintage = vintage
        self.region = region
        self.country = country
        self.grapeVarietiesText = grapeVarieties.joined(separator: "\n")
        self.wineTypeRawValue = wineType.rawValue
        self.volumeML = volumeML
        self.alcoholPercent = alcoholPercent
        self.ocrRawText = ocrRawText
        self.ocrObservationsData = ocrObservationsData
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    var grapeVarieties: [String] {
        get { grapeVarietiesText.split(separator: "\n").map(String.init) }
        set { grapeVarietiesText = newValue.joined(separator: "\n") }
    }

    var wineType: WineType {
        get { WineType(rawValue: wineTypeRawValue) ?? .other }
        set { wineTypeRawValue = newValue.rawValue }
    }
}

@Model
final class WineBottleRecord {
    @Attribute(.unique) var id: UUID
    var cellarID: UUID
    var wineID: UUID
    var lifecycleStateRawValue: String
    var acquiredAt: Date?
    var openedAt: Date?
    var finishedAt: Date?
    var remainingPercent: Int?
    var storageLocation: String?
    var purchasePrice: Double?
    var sourceImageAssetID: UUID?
    var labelImageAssetID: UUID?
    var thumbnailAssetID: UUID?
    var bottleShapeRawValue: String
    var templateID: String?
    var bottle3DAssetID: UUID?
    var tastingCount: Int
    var lastTastedAt: Date?
    var ratingSummary: Double?
    var tagsText: String
    var note: String?
    var createdAt: Date
    var updatedAt: Date
    var schemaVersion: Int

    init(
        id: UUID = UUID(),
        cellarID: UUID,
        wineID: UUID,
        lifecycleState: BottleLifecycleState = .owned,
        acquiredAt: Date? = .now,
        openedAt: Date? = nil,
        finishedAt: Date? = nil,
        remainingPercent: Int? = 100,
        storageLocation: String? = nil,
        purchasePrice: Double? = nil,
        sourceImageAssetID: UUID? = nil,
        labelImageAssetID: UUID? = nil,
        thumbnailAssetID: UUID? = nil,
        bottleShape: BottleShape = .generic,
        templateID: String? = nil,
        bottle3DAssetID: UUID? = nil,
        tastingCount: Int = 0,
        lastTastedAt: Date? = nil,
        ratingSummary: Double? = nil,
        tags: [String] = [],
        note: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.cellarID = cellarID
        self.wineID = wineID
        self.lifecycleStateRawValue = lifecycleState.rawValue
        self.acquiredAt = acquiredAt
        self.openedAt = openedAt
        self.finishedAt = finishedAt
        self.remainingPercent = remainingPercent
        self.storageLocation = storageLocation
        self.purchasePrice = purchasePrice
        self.sourceImageAssetID = sourceImageAssetID
        self.labelImageAssetID = labelImageAssetID
        self.thumbnailAssetID = thumbnailAssetID
        self.bottleShapeRawValue = bottleShape.rawValue
        self.templateID = templateID
        self.bottle3DAssetID = bottle3DAssetID
        self.tastingCount = tastingCount
        self.lastTastedAt = lastTastedAt
        self.ratingSummary = ratingSummary
        self.tagsText = tags.joined(separator: "\n")
        self.note = note
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.schemaVersion = schemaVersion
    }

    var lifecycleState: BottleLifecycleState {
        get { BottleLifecycleState(rawValue: lifecycleStateRawValue) ?? .owned }
        set { lifecycleStateRawValue = newValue.rawValue }
    }

    var bottleShape: BottleShape {
        get { BottleShape(rawValue: bottleShapeRawValue) ?? .generic }
        set { bottleShapeRawValue = newValue.rawValue }
    }

    var tags: [String] {
        get { tagsText.split(separator: "\n").map(String.init) }
        set { tagsText = newValue.joined(separator: "\n") }
    }
}

@Model
final class TastingSessionRecord {
    @Attribute(.unique) var id: UUID
    var bottleID: UUID
    var tastedAt: Date
    var rating: Int?
    var acidity: Int?
    var sweetness: Int?
    var tannin: Int?
    var body: Int?
    var alcohol: Int?
    var finish: Int?
    var aromaTagsText: String
    var palateTagsText: String
    var note: String?
    var servingTemperatureCelsius: Double?
    var openedHoursBeforeTasting: Double?

    init(id: UUID = UUID(), bottleID: UUID, draft: TastingDraft) {
        self.id = id
        self.bottleID = bottleID
        self.tastedAt = draft.tastedAt
        self.rating = draft.rating
        self.acidity = draft.acidity
        self.sweetness = draft.sweetness
        self.tannin = draft.tannin
        self.body = draft.body
        self.alcohol = draft.alcohol
        self.finish = draft.finish
        self.aromaTagsText = draft.aromaTags.joined(separator: "\n")
        self.palateTagsText = draft.palateTags.joined(separator: "\n")
        self.note = draft.note
        self.servingTemperatureCelsius = draft.servingTemperatureCelsius
        self.openedHoursBeforeTasting = draft.openedHoursBeforeTasting
    }

    var aromaTags: [String] {
        get { aromaTagsText.split(separator: "\n").map(String.init) }
        set { aromaTagsText = newValue.joined(separator: "\n") }
    }

    var palateTags: [String] {
        get { palateTagsText.split(separator: "\n").map(String.init) }
        set { palateTagsText = newValue.joined(separator: "\n") }
    }
}

@Model
final class PairingRecord {
    @Attribute(.unique) var id: UUID
    var tastingID: UUID?
    var bottleID: UUID
    var dishName: String
    var dishCategory: String?
    var score: Int
    var note: String?

    init(id: UUID = UUID(), tastingID: UUID? = nil, bottleID: UUID, draft: PairingDraft) {
        self.id = id
        self.tastingID = tastingID
        self.bottleID = bottleID
        self.dishName = draft.dishName
        self.dishCategory = draft.dishCategory
        self.score = draft.score
        self.note = draft.note
    }
}

@Model
final class MediaAssetRecord {
    @Attribute(.unique) var id: UUID
    var relativePath: String
    var kindRawValue: String
    var byteCount: Int64
    var createdAt: Date
    var checksum: String?

    init(id: UUID = UUID(), relativePath: String, kindRawValue: String, byteCount: Int64, createdAt: Date = .now, checksum: String? = nil) {
        self.id = id
        self.relativePath = relativePath
        self.kindRawValue = kindRawValue
        self.byteCount = byteCount
        self.createdAt = createdAt
        self.checksum = checksum
    }
}

@Model
final class Bottle3DAssetRecord {
    @Attribute(.unique) var id: UUID
    var templateID: String
    var templateVersion: String
    var textureAssetID: UUID?
    var sourceRawValue: String
    var generatedAt: Date
    var qualityRawValue: String

    init(id: UUID = UUID(), templateID: String, templateVersion: String, textureAssetID: UUID? = nil, sourceRawValue: String = "templateTextured", generatedAt: Date = .now, qualityRawValue: String = "preview") {
        self.id = id
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.textureAssetID = textureAssetID
        self.sourceRawValue = sourceRawValue
        self.generatedAt = generatedAt
        self.qualityRawValue = qualityRawValue
    }
}

@Model
final class BottleLifecycleEventRecord {
    @Attribute(.unique) var id: UUID
    var bottleID: UUID
    var fromStateRawValue: String?
    var toStateRawValue: String
    var occurredAt: Date
    var note: String?

    init(id: UUID = UUID(), bottleID: UUID, from: BottleLifecycleState?, to: BottleLifecycleState, occurredAt: Date = .now, note: String? = nil) {
        self.id = id
        self.bottleID = bottleID
        self.fromStateRawValue = from?.rawValue
        self.toStateRawValue = to.rawValue
        self.occurredAt = occurredAt
        self.note = note
    }
}

@Model
final class ProcessingJobRecord {
    @Attribute(.unique) var id: UUID
    var jobType: String
    var inputAssetIDsText: String
    var currentStep: String
    var progress: Double
    var statusRawValue: String
    var retryCount: Int
    var lastErrorCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(), jobType: String, inputAssetIDs: [UUID] = [], currentStep: String = "queued", progress: Double = 0, statusRawValue: String = "queued", retryCount: Int = 0, lastErrorCode: String? = nil, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.jobType = jobType
        self.inputAssetIDsText = inputAssetIDs.map(\.uuidString).joined(separator: "\n")
        self.currentStep = currentStep
        self.progress = progress
        self.statusRawValue = statusRawValue
        self.retryCount = retryCount
        self.lastErrorCode = lastErrorCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

enum CorkSchema {
    static let models: [any PersistentModel.Type] = [
        LocalCellarRecord.self,
        WineRecord.self,
        WineBottleRecord.self,
        TastingSessionRecord.self,
        PairingRecord.self,
        MediaAssetRecord.self,
        Bottle3DAssetRecord.self,
        BottleLifecycleEventRecord.self,
        ProcessingJobRecord.self
    ]
}

enum CorkSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)
    static let models: [any PersistentModel.Type] = CorkSchema.models
}

enum CorkMigrationPlan: SchemaMigrationPlan {
    static let schemas: [any VersionedSchema.Type] = [CorkSchemaV1.self]
    static let stages: [MigrationStage] = []
}

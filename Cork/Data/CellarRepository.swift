import Foundation
import SwiftData

struct WineDraft: Sendable {
    var name: String
    var producer: String?
    var region: String?
    var country: String?
    var grapeVarieties: [String]
    var vintage: Int?
    var wineType: WineType
    var volumeML: Int?
    var alcoholPercent: Double?
    var ocrRawText: String? = nil
    var ocrObservationsData: Data? = nil
}

struct BottleDraft: Sendable {
    var lifecycleState: BottleLifecycleState = .owned
    var acquiredAt: Date? = .now
    var storageLocation: String?
    var purchasePrice: Double?
    var bottleShape: BottleShape = .generic
    var note: String?
}

enum MediaAssetKind: String, Sendable {
    case original
    case label
    case thumbnail
}

@MainActor
final class CellarRepository {
    let context: ModelContext
    let commitContext: (ModelContext) throws -> Void
    private let fileManager: FileManager
    private let rootURL: URL

    init(context: ModelContext, fileManager: FileManager = .default,
         commitContext: @escaping (ModelContext) throws -> Void = { try $0.save() }) {
        self.context = context
        self.commitContext = commitContext
        self.fileManager = fileManager
        self.rootURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cork", isDirectory: true)
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        for directory in ["Media/Original", "Media/Labels", "Media/Thumbnails", "3D", "Jobs"] {
            try? fileManager.createDirectory(at: rootURL.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
    }

    func ensureDefaultCellar() throws -> UUID {
        var descriptor = FetchDescriptor<LocalCellarRecord>(sortBy: [SortDescriptor(\.createdAt)])
        descriptor.fetchLimit = 1
        if let cellar = try context.fetch(descriptor).first {
            return cellar.id
        }
        let cellar = LocalCellarRecord(name: "Default Cellar")
        context.insert(cellar)
        try context.save()
        return cellar.id
    }

    func fetchEntries(searchText: String = "", lifecycle: BottleLifecycleState? = nil, wineType: WineType? = nil, sort: CellarSort = .updated) throws -> [CellarEntry] {
        let wines = try context.fetch(FetchDescriptor<WineRecord>())
        let winesByID = Dictionary(uniqueKeysWithValues: wines.map { ($0.id, $0) })
        var bottleDescriptor = FetchDescriptor<WineBottleRecord>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        if let lifecycle {
            let raw = lifecycle.rawValue
            bottleDescriptor.predicate = #Predicate<WineBottleRecord> { $0.lifecycleStateRawValue == raw }
        }
        let bottles = try context.fetch(bottleDescriptor)
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        let entries = bottles.compactMap { bottle -> CellarEntry? in
            guard let wine = winesByID[bottle.wineID] else { return nil }
            let entry = makeEntry(wine: wine, bottle: bottle)
            guard wineType == nil || entry.wineType == wineType else { return nil }
            guard normalizedSearch.isEmpty || searchableText(for: entry).contains(normalizedSearch) else { return nil }
            return entry
        }

        switch sort {
        case .updated:
            return entries.sorted { $0.updatedAt > $1.updatedAt }
        case .name:
            return entries.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        case .vintage:
            return entries.sorted { ($0.vintage ?? 0) > ($1.vintage ?? 0) }
        case .rating:
            return entries.sorted { ($0.ratingSummary ?? -1) > ($1.ratingSummary ?? -1) }
        }
    }

    @discardableResult
    func createEntry(
        wineDraft: WineDraft,
        bottleDraft: BottleDraft,
        imageData: Data? = nil,
        labelImageData: Data? = nil,
        bottleCutoutImageData: Data? = nil
    ) throws -> CellarEntry {
        let cellarID = try ensureDefaultCellar()
        let now = Date.now
        let wine = WineRecord(
            name: wineDraft.name,
            producer: wineDraft.producer,
            vintage: wineDraft.vintage,
            region: wineDraft.region,
            country: wineDraft.country,
            grapeVarieties: wineDraft.grapeVarieties,
            wineType: wineDraft.wineType,
            volumeML: wineDraft.volumeML,
            alcoholPercent: wineDraft.alcoholPercent,
            ocrRawText: wineDraft.ocrRawText,
            ocrObservationsData: wineDraft.ocrObservationsData,
            createdAt: now,
            updatedAt: now
        )
        context.insert(wine)

        var writtenMediaURLs: [URL] = []

        do {
            var sourceAssetID: UUID?
            if let imageData {
                let assetID = try saveMedia(data: imageData, kind: .original)
                sourceAssetID = assetID
                writtenMediaURLs.append(mediaURL(id: assetID, kind: .original))
            }
            var labelAssetID: UUID?
            if let labelImageData {
                let assetID = try saveMedia(data: labelImageData, kind: .label)
                labelAssetID = assetID
                writtenMediaURLs.append(mediaURL(id: assetID, kind: .label))
            }
            var thumbnailAssetID: UUID?
            if let bottleCutoutImageData {
                let displayImageData = BottleImageNormalizer().normalize(data: bottleCutoutImageData)
                    ?? bottleCutoutImageData
                let assetID = try saveMedia(data: displayImageData, kind: .thumbnail)
                thumbnailAssetID = assetID
                writtenMediaURLs.append(mediaURL(id: assetID, kind: .thumbnail))
            }
            let bottle = WineBottleRecord(
                cellarID: cellarID,
                wineID: wine.id,
                lifecycleState: bottleDraft.lifecycleState,
                acquiredAt: bottleDraft.acquiredAt,
                storageLocation: bottleDraft.storageLocation,
                purchasePrice: bottleDraft.purchasePrice,
                sourceImageAssetID: sourceAssetID,
                labelImageAssetID: labelAssetID,
                thumbnailAssetID: thumbnailAssetID,
                bottleShape: bottleDraft.bottleShape,
                templateID: templateID(for: bottleDraft.bottleShape),
                note: bottleDraft.note,
                createdAt: now,
                updatedAt: now
            )
            context.insert(bottle)
            context.insert(BottleLifecycleEventRecord(bottleID: bottle.id, from: nil, to: bottleDraft.lifecycleState, occurredAt: now))
            try saveLocalChanges([bottle.id])
            return makeEntry(wine: wine, bottle: bottle)
        } catch {
            context.rollback()
            for url in writtenMediaURLs {
                try? fileManager.removeItem(at: url)
            }
            throw error
        }
    }

    func updateLifecycle(bottleID: UUID, to newState: BottleLifecycleState) throws {
        guard let bottle = try fetchBottle(id: bottleID) else { return }
        let oldState = bottle.lifecycleState
        guard oldState != newState else { return }
        let now = Date.now
        bottle.lifecycleState = newState
        switch newState {
        case .owned:
            bottle.openedAt = nil
            bottle.finishedAt = nil
            bottle.remainingPercent = 100
        case .opened:
            bottle.openedAt = bottle.openedAt ?? now
            bottle.finishedAt = nil
            bottle.remainingPercent = max(1, bottle.remainingPercent ?? 100)
        case .finished:
            bottle.finishedAt = bottle.finishedAt ?? now
            bottle.remainingPercent = 0
        }
        bottle.updatedAt = now
        context.insert(BottleLifecycleEventRecord(bottleID: bottle.id, from: oldState, to: newState, occurredAt: now))
        try saveLocalChanges([bottleID])
    }

    func updateBottle(bottleID: UUID, storageLocation: String?, note: String?, remainingPercent: Int?) throws {
        guard let bottle = try fetchBottle(id: bottleID) else { return }
        bottle.storageLocation = storageLocation?.nilIfBlank
        bottle.note = note?.nilIfBlank
        bottle.remainingPercent = remainingPercent.map { min(max($0, 0), 100) }
        bottle.updatedAt = .now
        try saveLocalChanges([bottleID])
    }

    func addTasting(to bottleID: UUID, draft: TastingDraft) throws {
        guard let bottle = try fetchBottle(id: bottleID) else { return }
        let tasting = TastingSessionRecord(bottleID: bottleID, draft: draft)
        context.insert(tasting)
        let tastings = try fetchTastings(for: bottleID)
        bottle.tastingCount = tastings.count
        bottle.lastTastedAt = tastings.map(\.tastedAt).max()
        let ratings = tastings.compactMap(\.rating)
        bottle.ratingSummary = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        bottle.tags = Array(Set(tastings.flatMap { $0.aromaTags + $0.palateTags } + draft.aromaTags + draft.palateTags)).sorted()
        bottle.updatedAt = .now
        try saveLocalChanges([bottleID])
    }

    func addPairing(to bottleID: UUID, draft: PairingDraft) throws {
        guard try fetchBottle(id: bottleID) != nil else { return }
        context.insert(PairingRecord(bottleID: bottleID, draft: draft))
        try saveLocalChanges([bottleID])
    }

    func fetchTastings(for bottleID: UUID? = nil) throws -> [TastingSessionRecord] {
        if let bottleID {
            return try context.fetch(FetchDescriptor<TastingSessionRecord>(predicate: #Predicate { $0.bottleID == bottleID }))
        }
        return try context.fetch(FetchDescriptor<TastingSessionRecord>())
    }

    func exportArchiveData() throws -> Data {
        let archive = CorkArchive(
            cellars: try context.fetch(FetchDescriptor<LocalCellarRecord>()).map {
                CellarArchiveCellar(id: $0.id, name: $0.name, createdAt: $0.createdAt, updatedAt: $0.updatedAt, schemaVersion: $0.schemaVersion)
            },
            wines: try context.fetch(FetchDescriptor<WineRecord>()).map {
                CellarArchiveWine(
                    id: $0.id,
                    name: $0.name,
                    producer: $0.producer,
                    winery: $0.winery,
                    vintage: $0.vintage,
                    region: $0.region,
                    country: $0.country,
                    grapeVarieties: $0.grapeVarieties,
                    wineType: $0.wineType,
                    volumeML: $0.volumeML,
                    alcoholPercent: $0.alcoholPercent,
                    ocrRawText: $0.ocrRawText,
                    ocrObservationsData: $0.ocrObservationsData,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    schemaVersion: $0.schemaVersion
                )
            },
            bottles: try context.fetch(FetchDescriptor<WineBottleRecord>()).map {
                CellarArchiveBottle(
                    id: $0.id,
                    cellarID: $0.cellarID,
                    wineID: $0.wineID,
                    lifecycleState: $0.lifecycleState,
                    acquiredAt: $0.acquiredAt,
                    openedAt: $0.openedAt,
                    finishedAt: $0.finishedAt,
                    remainingPercent: $0.remainingPercent,
                    storageLocation: $0.storageLocation,
                    purchasePrice: $0.purchasePrice,
                    sourceImageAssetID: $0.sourceImageAssetID,
                    labelImageAssetID: $0.labelImageAssetID,
                    thumbnailAssetID: $0.thumbnailAssetID,
                    bottleShape: $0.bottleShape,
                    templateID: $0.templateID,
                    bottle3DAssetID: $0.bottle3DAssetID,
                    tastingCount: $0.tastingCount,
                    lastTastedAt: $0.lastTastedAt,
                    ratingSummary: $0.ratingSummary,
                    tags: $0.tags,
                    note: $0.note,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    schemaVersion: $0.schemaVersion
                )
            },
            tastings: try context.fetch(FetchDescriptor<TastingSessionRecord>()).map {
                CellarArchiveTasting(
                    id: $0.id,
                    bottleID: $0.bottleID,
                    tastedAt: $0.tastedAt,
                    rating: $0.rating,
                    acidity: $0.acidity,
                    sweetness: $0.sweetness,
                    tannin: $0.tannin,
                    body: $0.body,
                    alcohol: $0.alcohol,
                    finish: $0.finish,
                    aromaTags: $0.aromaTags,
                    palateTags: $0.palateTags,
                    note: $0.note,
                    servingTemperatureCelsius: $0.servingTemperatureCelsius,
                    openedHoursBeforeTasting: $0.openedHoursBeforeTasting
                )
            },
            pairings: try context.fetch(FetchDescriptor<PairingRecord>()).map {
                CellarArchivePairing(id: $0.id, tastingID: $0.tastingID, bottleID: $0.bottleID, dishName: $0.dishName, dishCategory: $0.dishCategory, score: $0.score, note: $0.note)
            },
            mediaAssets: try exportMediaAssets(),
            bottle3DAssets: try context.fetch(FetchDescriptor<Bottle3DAssetRecord>()).map {
                CellarArchiveBottle3DAsset(id: $0.id, templateID: $0.templateID, templateVersion: $0.templateVersion, textureAssetID: $0.textureAssetID, sourceRawValue: $0.sourceRawValue, generatedAt: $0.generatedAt, qualityRawValue: $0.qualityRawValue)
            },
            lifecycleEvents: try context.fetch(FetchDescriptor<BottleLifecycleEventRecord>()).map {
                CellarArchiveLifecycleEvent(id: $0.id, bottleID: $0.bottleID, fromState: $0.fromStateRawValue.flatMap { BottleLifecycleState(rawValue: $0) }, toState: BottleLifecycleState(rawValue: $0.toStateRawValue) ?? .owned, occurredAt: $0.occurredAt, note: $0.note)
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(archive)
    }

    @discardableResult
    func importArchiveData(_ data: Data) throws -> CorkArchiveImportResult {
        guard data.count <= 200 * 1024 * 1024 else { throw CorkArchiveError.archiveTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(CorkArchive.self, from: data)
        try archive.validate()

        let existingCellarIDs = Set(try context.fetch(FetchDescriptor<LocalCellarRecord>()).map(\.id))
        let existingWineIDs = Set(try context.fetch(FetchDescriptor<WineRecord>()).map(\.id))
        let existingBottleIDs = Set(try context.fetch(FetchDescriptor<WineBottleRecord>()).map(\.id))
        let existingTastingIDs = Set(try context.fetch(FetchDescriptor<TastingSessionRecord>()).map(\.id))
        let existingPairingIDs = Set(try context.fetch(FetchDescriptor<PairingRecord>()).map(\.id))
        let existingMediaIDs = Set(try context.fetch(FetchDescriptor<MediaAssetRecord>()).map(\.id))
        let existing3DIDs = Set(try context.fetch(FetchDescriptor<Bottle3DAssetRecord>()).map(\.id))
        let existingEventIDs = Set(try context.fetch(FetchDescriptor<BottleLifecycleEventRecord>()).map(\.id))

        var insertedCellarIDs = existingCellarIDs
        var insertedWineIDs = existingWineIDs
        var insertedBottleIDs = existingBottleIDs
        var insertedMediaIDs = existingMediaIDs
        var inserted3DIDs = existing3DIDs
        var insertedTastingIDs = existingTastingIDs
        var insertedPairingIDs = existingPairingIDs
        var insertedEventIDs = existingEventIDs
        var writtenMediaURLs: [URL] = []
        var counts = Counts()

        do {
            for cellar in archive.cellars where insertedCellarIDs.insert(cellar.id).inserted {
                context.insert(LocalCellarRecord(id: cellar.id, name: cellar.name, createdAt: cellar.createdAt, updatedAt: cellar.updatedAt, schemaVersion: cellar.schemaVersion))
                counts.cellars += 1
            }
            for wine in archive.wines where insertedWineIDs.insert(wine.id).inserted {
                context.insert(WineRecord(id: wine.id, name: wine.name, producer: wine.producer, winery: wine.winery, vintage: wine.vintage, region: wine.region, country: wine.country, grapeVarieties: wine.grapeVarieties, wineType: wine.wineType, volumeML: wine.volumeML, alcoholPercent: wine.alcoholPercent, ocrRawText: wine.ocrRawText, ocrObservationsData: wine.ocrObservationsData, createdAt: wine.createdAt, updatedAt: wine.updatedAt, schemaVersion: wine.schemaVersion))
                counts.wines += 1
            }
            for media in archive.mediaAssets where insertedMediaIDs.insert(media.id).inserted {
                let relativePath = try relativeMediaPath(for: media)
                let url = rootURL.appendingPathComponent(relativePath)
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try media.data.write(to: url, options: .atomic)
                writtenMediaURLs.append(url)
                context.insert(MediaAssetRecord(id: media.id, relativePath: relativePath, kindRawValue: media.kindRawValue, byteCount: Int64(media.data.count), createdAt: media.createdAt, checksum: media.checksum))
                counts.mediaAssets += 1
            }
            for asset in archive.bottle3DAssets where inserted3DIDs.insert(asset.id).inserted {
                context.insert(Bottle3DAssetRecord(id: asset.id, templateID: asset.templateID, templateVersion: asset.templateVersion, textureAssetID: asset.textureAssetID, sourceRawValue: asset.sourceRawValue, generatedAt: asset.generatedAt, qualityRawValue: asset.qualityRawValue))
                counts.bottle3DAssets += 1
            }
            for bottle in archive.bottles where insertedBottleIDs.insert(bottle.id).inserted {
                context.insert(WineBottleRecord(id: bottle.id, cellarID: bottle.cellarID, wineID: bottle.wineID, lifecycleState: bottle.lifecycleState, acquiredAt: bottle.acquiredAt, openedAt: bottle.openedAt, finishedAt: bottle.finishedAt, remainingPercent: bottle.remainingPercent, storageLocation: bottle.storageLocation, purchasePrice: bottle.purchasePrice, sourceImageAssetID: bottle.sourceImageAssetID, labelImageAssetID: bottle.labelImageAssetID, thumbnailAssetID: bottle.thumbnailAssetID, bottleShape: bottle.bottleShape, templateID: bottle.templateID, bottle3DAssetID: bottle.bottle3DAssetID, tastingCount: bottle.tastingCount, lastTastedAt: bottle.lastTastedAt, ratingSummary: bottle.ratingSummary, tags: bottle.tags, note: bottle.note, createdAt: bottle.createdAt, updatedAt: bottle.updatedAt, schemaVersion: bottle.schemaVersion))
                counts.bottles += 1
            }
            for tasting in archive.tastings where insertedTastingIDs.insert(tasting.id).inserted {
                let draft = TastingDraft(rating: tasting.rating, acidity: tasting.acidity, sweetness: tasting.sweetness, tannin: tasting.tannin, body: tasting.body, alcohol: tasting.alcohol, finish: tasting.finish, aromaTags: tasting.aromaTags, palateTags: tasting.palateTags, note: tasting.note, tastedAt: tasting.tastedAt, servingTemperatureCelsius: tasting.servingTemperatureCelsius, openedHoursBeforeTasting: tasting.openedHoursBeforeTasting)
                let record = TastingSessionRecord(id: tasting.id, bottleID: tasting.bottleID, draft: draft)
                context.insert(record)
                counts.tastings += 1
            }
            for pairing in archive.pairings where insertedPairingIDs.insert(pairing.id).inserted {
                context.insert(PairingRecord(id: pairing.id, tastingID: pairing.tastingID, bottleID: pairing.bottleID, draft: PairingDraft(dishName: pairing.dishName, dishCategory: pairing.dishCategory, score: pairing.score, note: pairing.note)))
                counts.pairings += 1
            }
            for event in archive.lifecycleEvents where insertedEventIDs.insert(event.id).inserted {
                context.insert(BottleLifecycleEventRecord(id: event.id, bottleID: event.bottleID, from: event.fromState, to: event.toState, occurredAt: event.occurredAt, note: event.note))
                counts.lifecycleEvents += 1
            }
            try saveLocalChanges(Set(archive.bottles.map(\.id) + archive.tastings.map(\.bottleID) + archive.pairings.map(\.bottleID) + archive.lifecycleEvents.map(\.bottleID)))
        } catch {
            context.rollback()
            for url in writtenMediaURLs { try? fileManager.removeItem(at: url) }
            throw error
        }

        return CorkArchiveImportResult(cellarsInserted: counts.cellars, winesInserted: counts.wines, bottlesInserted: counts.bottles, tastingsInserted: counts.tastings, pairingsInserted: counts.pairings, mediaAssetsInserted: counts.mediaAssets, bottle3DAssetsInserted: counts.bottle3DAssets, lifecycleEventsInserted: counts.lifecycleEvents)
    }

    func tasteProfile() throws -> TasteProfile {
        let tastings = try fetchTastings()
        let tags = tastings.flatMap { $0.aromaTags + $0.palateTags }
        let counts = Dictionary(grouping: tags, by: { $0 }).mapValues(\.count)
        let favorites = counts.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.prefix(5).map(\.key)
        let pairings = try context.fetch(FetchDescriptor<PairingRecord>())
        var pairingScoresByCategory: [String: [Int]] = [:]
        for pairing in pairings {
            guard let category = pairing.dishCategory?.nilIfBlank else { continue }
            pairingScoresByCategory[category, default: []].append(pairing.score)
        }
        var pairingCategories: [PairingCategorySummary] = []
        pairingCategories.reserveCapacity(pairingScoresByCategory.count)
        for (category, scores) in pairingScoresByCategory {
            let averageScore = average(scores) ?? 0
            pairingCategories.append(PairingCategorySummary(category: category, averageScore: averageScore, count: scores.count))
        }
        pairingCategories.sort { lhs, rhs in
            lhs.averageScore == rhs.averageScore ? lhs.category < rhs.category : lhs.averageScore > rhs.averageScore
        }
        let acidityValues = tastings.compactMap(\.acidity)
        let sweetnessValues = tastings.compactMap(\.sweetness)
        let tanninValues = tastings.compactMap(\.tannin)
        let bodyValues = tastings.compactMap(\.body)
        return TasteProfile(
            tastingCount: tastings.count,
            averageAcidity: average(acidityValues),
            averageSweetness: average(sweetnessValues),
            averageTannin: average(tanninValues),
            averageBody: average(bodyValues),
            varianceAcidity: variance(acidityValues),
            varianceSweetness: variance(sweetnessValues),
            varianceTannin: variance(tanninValues),
            varianceBody: variance(bodyValues),
            favoriteTags: favorites,
            pairingCategories: pairingCategories
        )
    }

    func deleteEntry(bottleID: UUID) throws {
        guard let bottle = try fetchBottle(id: bottleID) else { return }
        let wineID = bottle.wineID
        var mediaURLs: [URL] = []
        for assetID in [bottle.sourceImageAssetID, bottle.labelImageAssetID, bottle.thumbnailAssetID].compactMap({ $0 }) {
            if let asset = try context.fetch(FetchDescriptor<MediaAssetRecord>(predicate: #Predicate { $0.id == assetID })).first {
                mediaURLs.append(rootURL.appendingPathComponent(asset.relativePath))
                context.delete(asset)
            }
        }
        let tastings = try fetchTastings(for: bottleID)
        for tasting in tastings { context.delete(tasting) }
        let pairings = try context.fetch(FetchDescriptor<PairingRecord>(predicate: #Predicate { $0.bottleID == bottleID }))
        for pairing in pairings { context.delete(pairing) }
        let events = try context.fetch(FetchDescriptor<BottleLifecycleEventRecord>(predicate: #Predicate { $0.bottleID == bottleID }))
        for event in events { context.delete(event) }
        context.delete(bottle)
        let remainingBottleCount = try context.fetch(
            FetchDescriptor<WineBottleRecord>(predicate: #Predicate { $0.wineID == wineID && $0.id != bottleID })
        ).count
        if remainingBottleCount == 0,
           let wine = try context.fetch(FetchDescriptor<WineRecord>(predicate: #Predicate { $0.id == wineID })).first {
            context.delete(wine)
        }
        try saveLocalChanges([bottleID])
        for url in mediaURLs { try? fileManager.removeItem(at: url) }
    }

    func loadImageData(for assetID: UUID) throws -> Data? {
        guard let asset = try context.fetch(FetchDescriptor<MediaAssetRecord>(predicate: #Predicate { $0.id == assetID })).first else { return nil }
        return try Data(contentsOf: rootURL.appendingPathComponent(asset.relativePath))
    }

    private func fetchBottle(id: UUID) throws -> WineBottleRecord? {
        try context.fetch(FetchDescriptor<WineBottleRecord>(predicate: #Predicate { $0.id == id })).first
    }

    private func saveMedia(data: Data, kind: MediaAssetKind) throws -> UUID {
        let id = UUID()
        let url = mediaURL(id: id, kind: kind)
        try data.write(to: url, options: .atomic)
        let relativePath = url.path.replacingOccurrences(of: rootURL.path + "/", with: "")
        context.insert(MediaAssetRecord(id: id, relativePath: relativePath, kindRawValue: kind.rawValue, byteCount: Int64(data.count)))
        return id
    }

    private func mediaURL(id: UUID, kind: MediaAssetKind) -> URL {
        let directory: String
        switch kind {
        case .original: directory = "Media/Original"
        case .label: directory = "Media/Labels"
        case .thumbnail: directory = "Media/Thumbnails"
        }
        return rootURL.appendingPathComponent(directory).appendingPathComponent("\(id.uuidString).dat")
    }

    private func exportMediaAssets() throws -> [CellarArchiveMediaAsset] {
        try context.fetch(FetchDescriptor<MediaAssetRecord>()).map { asset in
            let url = rootURL.appendingPathComponent(asset.relativePath)
            guard let data = try? Data(contentsOf: url) else {
                throw CorkArchiveError.brokenReference
            }
            return CellarArchiveMediaAsset(id: asset.id, kindRawValue: asset.kindRawValue, byteCount: Int64(data.count), createdAt: asset.createdAt, checksum: asset.checksum, data: data)
        }
    }

    private func relativeMediaPath(for media: CellarArchiveMediaAsset) throws -> String {
        guard let kind = MediaAssetKind(rawValue: media.kindRawValue) else { throw CorkArchiveError.invalidMediaKind }
        let directory: String
        switch kind {
        case .original: directory = "Media/Original"
        case .label: directory = "Media/Labels"
        case .thumbnail: directory = "Media/Thumbnails"
        }
        return "\(directory)/\(media.id.uuidString).dat"
    }

    private func deleteMedia(id: UUID) throws {
        guard let asset = try context.fetch(FetchDescriptor<MediaAssetRecord>(predicate: #Predicate { $0.id == id })).first else { return }
        let url = rootURL.appendingPathComponent(asset.relativePath)
        try? fileManager.removeItem(at: url)
        context.delete(asset)
    }

    private func makeEntry(wine: WineRecord, bottle: WineBottleRecord) -> CellarEntry {
        CellarEntry(
            id: bottle.id,
            cellarID: bottle.cellarID,
            wineID: wine.id,
            displayName: wine.name,
            producer: wine.producer,
            region: wine.region,
            country: wine.country,
            grapeVarieties: wine.grapeVarieties,
            vintage: wine.vintage,
            wineType: wine.wineType,
            volumeML: wine.volumeML,
            alcoholPercent: wine.alcoholPercent,
            ocrRawText: wine.ocrRawText,
            ocrObservationsData: wine.ocrObservationsData,
            lifecycleState: bottle.lifecycleState,
            storageLocation: bottle.storageLocation,
            acquiredAt: bottle.acquiredAt,
            openedAt: bottle.openedAt,
            finishedAt: bottle.finishedAt,
            remainingPercent: bottle.remainingPercent,
            purchasePrice: bottle.purchasePrice,
            sourceImageAssetID: bottle.sourceImageAssetID,
            labelImageAssetID: bottle.labelImageAssetID,
            thumbnailAssetID: bottle.thumbnailAssetID,
            bottleShape: bottle.bottleShape,
            templateID: bottle.templateID,
            bottle3DAssetID: bottle.bottle3DAssetID,
            tastingCount: bottle.tastingCount,
            lastTastedAt: bottle.lastTastedAt,
            ratingSummary: bottle.ratingSummary,
            tags: bottle.tags,
            note: bottle.note,
            createdAt: bottle.createdAt,
            updatedAt: bottle.updatedAt,
            schemaVersion: bottle.schemaVersion
        )
    }

    private func searchableText(for entry: CellarEntry) -> String {
        [entry.displayName, entry.producer, entry.region, entry.country, entry.grapeVarieties.joined(separator: " "), entry.storageLocation, entry.tags.joined(separator: " ")]
            .compactMap { $0 }
            .joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func templateID(for shape: BottleShape) -> String { "\(shape.rawValue)-v1" }

    private func average(_ values: [Int]) -> Double? {
        values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count)
    }

    private func variance(_ values: [Int]) -> Double? {
        guard values.count >= 2, let mean = average(values) else { return nil }
        return values.reduce(0) { partial, value in
            let delta = Double(value) - mean
            return partial + delta * delta
        } / Double(values.count)
    }

    private struct Counts {
        var cellars = 0
        var wines = 0
        var bottles = 0
        var tastings = 0
        var pairings = 0
        var mediaAssets = 0
        var bottle3DAssets = 0
        var lifecycleEvents = 0
    }
}

private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

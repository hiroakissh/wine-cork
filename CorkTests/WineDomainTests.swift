import XCTest
import SwiftData
import UIKit
@testable import Cork

final class WineDomainTests: XCTestCase {
    func testLifecycleStatesExposeStableUserLabels() {
        XCTAssertEqual(BottleLifecycleState.owned.displayName, "所持")
        XCTAssertEqual(BottleLifecycleState.opened.displayName, "開栓中")
        XCTAssertEqual(BottleLifecycleState.finished.displayName, "飲了")
    }

    func testQuadrilateralRejectsSelfCollapsedGeometry() {
        let invalid = Quadrilateral(
            topLeft: CGPoint(x: 0, y: 0),
            topRight: CGPoint(x: 0, y: 0),
            bottomLeft: CGPoint(x: 0, y: 0),
            bottomRight: CGPoint(x: 0, y: 0)
        )
        XCTAssertFalse(invalid.isValid)
    }

    func testShapeClassifierAlwaysProvidesGenericFallback() {
        let candidates = RuleBasedBottleShapeClassifier().classify(features: BottleShapeFeatures(aspectRatio: 3.0, shoulderHeight: 0.2, neckLength: 0.3, bodyWidthPosition: 0.5, sparklingLikelihood: 0))
        XCTAssertEqual(candidates.count, BottleShape.allCases.count)
        XCTAssertTrue(candidates.contains { $0.shape == .generic })
        XCTAssertTrue(candidates.allSatisfy { $0.confidence >= 0 })
    }

    func testOCRParserExtractsRegistrationCandidates() {
        let result = OCRResult(observations: [
            OCRObservation(text: "Chateau Example", confidence: 0.98, boundingBox: .zero),
            OCRObservation(text: "Producer: Example Winery", confidence: 0.97, boundingBox: .zero),
            OCRObservation(text: "Region: Bordeaux", confidence: 0.96, boundingBox: .zero),
            OCRObservation(text: "Cabernet Sauvignon 2021", confidence: 0.94, boundingBox: .zero),
            OCRObservation(text: "750 mL 13.5%", confidence: 0.92, boundingBox: .zero),
            OCRObservation(text: "赤ワイン", confidence: 0.9, boundingBox: .zero)
        ])

        let candidate = RuleBasedOCRMetadataParser().parse(result)

        XCTAssertEqual(candidate.probableName, "Chateau Example")
        XCTAssertEqual(candidate.probableProducer, "Example Winery")
        XCTAssertEqual(candidate.probableRegion, "Bordeaux")
        XCTAssertEqual(candidate.vintage, 2021)
        XCTAssertEqual(candidate.volumeML, 750)
        XCTAssertEqual(candidate.alcoholPercent, 13.5)
        XCTAssertEqual(candidate.grapeVarieties, ["Cabernet Sauvignon"])
        XCTAssertEqual(candidate.wineType, .red)
    }

    func testImageNormalizerHandlesCameraOrientedImages() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 240))
        let baseImage = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 240))
        }
        let cameraImage = UIImage(cgImage: try XCTUnwrap(baseImage.cgImage), scale: 1, orientation: .right)

        let normalizedData = try XCTUnwrap(ImageNormalizer().normalize(image: cameraImage))
        let normalizedImage = try XCTUnwrap(UIImage(data: normalizedData))

        XCTAssertGreaterThan(normalizedImage.size.width, 0)
        XCTAssertGreaterThan(normalizedImage.size.height, 0)
    }

    func testBottleImageNormalizerUsesStableTransparentCanvas() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let source = UIGraphicsImageRenderer(
            size: CGSize(width: 300, height: 500),
            format: format
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 105, y: 80, width: 90, height: 360))
        }

        let data = try XCTUnwrap(BottleImageNormalizer().normalize(image: source))
        let normalized = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(normalized.size, BottleImageNormalizer.canvasSize)
        XCTAssertTrue(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }
}

@MainActor
final class CellarRepositoryTests: XCTestCase {
    private var container: ModelContainer!
    private var repository: CellarRepository!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: Schema(CorkSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        repository = CellarRepository(context: container.mainContext)
    }

    override func tearDown() {
        repository = nil
        container = nil
        super.tearDown()
    }

    func testCreateAndFilterEntry() throws {
        let entry = try repository.createEntry(
            wineDraft: WineDraft(name: "Test Rouge", producer: "Example", region: "Bordeaux", country: "France", grapeVarieties: ["Merlot"], vintage: 2022, wineType: .red, volumeML: 750, alcoholPercent: 13),
            bottleDraft: BottleDraft(storageLocation: "Rack 01", bottleShape: .bordeaux)
        )

        XCTAssertEqual(try repository.fetchEntries().count, 1)
        XCTAssertEqual(try repository.fetchEntries(searchText: "bordeaux").first?.id, entry.id)
        XCTAssertEqual(try repository.fetchEntries(lifecycle: .owned).first?.id, entry.id)
    }

    func testLifecycleAndTasteProfileArePersisted() throws {
        let entry = try repository.createEntry(
            wineDraft: WineDraft(name: "Profile Wine", producer: nil, region: nil, country: nil, grapeVarieties: [], vintage: nil, wineType: .red, volumeML: 750, alcoholPercent: nil),
            bottleDraft: BottleDraft()
        )
        try repository.updateLifecycle(bottleID: entry.id, to: .opened)
        try repository.addTasting(to: entry.id, draft: TastingDraft(rating: 4, acidity: 4, sweetness: 2, tannin: 3, body: 4, alcohol: nil, finish: nil, aromaTags: ["ベリー"], palateTags: [], note: nil, tastedAt: .now, servingTemperatureCelsius: nil, openedHoursBeforeTasting: nil))

        let saved = try XCTUnwrap(try repository.fetchEntries().first)
        XCTAssertEqual(saved.lifecycleState, .opened)
        XCTAssertEqual(saved.tastingCount, 1)
        XCTAssertEqual(saved.ratingSummary, 4)
        XCTAssertEqual(try repository.tasteProfile().averageBody, 4)
    }

    func testTasteProfileIncludesVarianceAndPairingCategories() throws {
        let entry = try repository.createEntry(
            wineDraft: WineDraft(name: "Profile Detail Wine", producer: nil, region: nil, country: nil, grapeVarieties: [], vintage: nil, wineType: .red, volumeML: 750, alcoholPercent: nil),
            bottleDraft: BottleDraft()
        )
        try repository.addTasting(to: entry.id, draft: TastingDraft(rating: 4, acidity: 2, sweetness: 3, tannin: 3, body: 4, alcohol: nil, finish: nil, aromaTags: [], palateTags: [], note: nil, tastedAt: .now, servingTemperatureCelsius: nil, openedHoursBeforeTasting: nil))
        try repository.addTasting(to: entry.id, draft: TastingDraft(rating: 5, acidity: 4, sweetness: 3, tannin: 3, body: 4, alcohol: nil, finish: nil, aromaTags: [], palateTags: [], note: nil, tastedAt: .now, servingTemperatureCelsius: nil, openedHoursBeforeTasting: nil))
        try repository.addPairing(to: entry.id, draft: PairingDraft(dishName: "魚", dishCategory: "魚介", score: 4, note: nil))
        try repository.addPairing(to: entry.id, draft: PairingDraft(dishName: "寿司", dishCategory: "魚介", score: 5, note: nil))

        let profile = try repository.tasteProfile()
        XCTAssertEqual(profile.varianceAcidity, 1)
        XCTAssertEqual(profile.pairingCategories.first?.category, "魚介")
        XCTAssertEqual(profile.pairingCategories.first?.averageScore, 4.5)
        XCTAssertEqual(profile.pairingCategories.first?.count, 2)
    }

    func testLabelImageIsPersistedAlongsideSourceImage() throws {
        let source = Data([0x01, 0x02])
        let label = Data([0x03, 0x04])
        let cutoutRenderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 240))
        let cutout = try XCTUnwrap(cutoutRenderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 25, y: 10, width: 50, height: 220))
        }.pngData())
        let entry = try repository.createEntry(
            wineDraft: WineDraft(name: "Label Wine", producer: nil, region: nil, country: nil, grapeVarieties: [], vintage: nil, wineType: .white, volumeML: 750, alcoholPercent: nil),
            bottleDraft: BottleDraft(),
            imageData: source,
            labelImageData: label,
            bottleCutoutImageData: cutout
        )

        let saved = try XCTUnwrap(try repository.fetchEntries().first)
        XCTAssertEqual(saved.id, entry.id)
        XCTAssertEqual(try XCTUnwrap(saved.sourceImageAssetID) != saved.labelImageAssetID, true)
        XCTAssertEqual(try repository.loadImageData(for: XCTUnwrap(saved.labelImageAssetID)), label)
        let storedCutout = try XCTUnwrap(repository.loadImageData(for: XCTUnwrap(saved.thumbnailAssetID)))
        let storedImage = try XCTUnwrap(UIImage(data: storedCutout))
        XCTAssertEqual(storedImage.size, BottleImageNormalizer.canvasSize)
        XCTAssertNotEqual(storedCutout, cutout)
    }

    func testArchiveRoundTripRestoresCellarAndExperiences() throws {
        let entry = try repository.createEntry(
            wineDraft: WineDraft(name: "Archive Wine", producer: "Cork Winery", region: "Napa", country: "US", grapeVarieties: ["Cabernet Sauvignon"], vintage: 2021, wineType: .red, volumeML: 750, alcoholPercent: 14, ocrRawText: "Archive Wine 2021", ocrObservationsData: Data([0x01, 0x02])),
            bottleDraft: BottleDraft(storageLocation: "Rack A", bottleShape: .bordeaux)
        )
        try repository.addTasting(to: entry.id, draft: TastingDraft(rating: 5, acidity: 4, sweetness: 2, tannin: 4, body: 5, alcohol: nil, finish: nil, aromaTags: ["カシス"], palateTags: ["スパイス"], note: "保存テスト", tastedAt: .now, servingTemperatureCelsius: 16, openedHoursBeforeTasting: 1))
        try repository.addPairing(to: entry.id, draft: PairingDraft(dishName: "ステーキ", dishCategory: "肉", score: 5, note: nil))

        let data = try repository.exportArchiveData()
        let importedContainer = try ModelContainer(
            for: Schema(CorkSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        let importedRepository = CellarRepository(context: importedContainer.mainContext)
        let result = try importedRepository.importArchiveData(data)

        XCTAssertEqual(result.bottlesInserted, 1)
        XCTAssertEqual(result.tastingsInserted, 1)
        XCTAssertEqual(result.pairingsInserted, 1)
        let restored = try XCTUnwrap(try importedRepository.fetchEntries().first)
        XCTAssertEqual(restored.displayName, "Archive Wine")
        XCTAssertEqual(restored.storageLocation, "Rack A")
        XCTAssertEqual(restored.ocrRawText, "Archive Wine 2021")
        XCTAssertEqual(restored.ocrObservationsData, Data([0x01, 0x02]))
        XCTAssertEqual(try importedRepository.tasteProfile().tastingCount, 1)
    }
}

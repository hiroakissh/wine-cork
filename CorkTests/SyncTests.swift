import Foundation
import SwiftData
import XCTest
@testable import Cork

@MainActor
final class SyncTests: XCTestCase {
    private func container(url: URL? = nil, v1: Bool = false) throws -> ModelContainer {
        let schema = Schema(v1 ? CorkSchemaV1.models : CorkSchema.models)
        let config = url.map { ModelConfiguration(schema: schema, url: $0) }
            ?? ModelConfiguration(isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: v1 ? nil : CorkMigrationPlan.self, configurations: [config])
    }

    private func create(_ repository: CellarRepository, name: String = "Test Wine") throws -> CellarEntry {
        try repository.createEntry(
            wineDraft: WineDraft(name: name, producer: "Test", region: "Bordeaux", country: "France",
                                 grapeVarieties: ["Merlot"], vintage: 2021, wineType: .red, volumeML: 750,
                                 alcoholPercent: 13, ocrRawText: "Private OCR"),
            bottleDraft: BottleDraft(storageLocation: "Rack A", purchasePrice: 3500), imageData: Data([1, 2, 3]))
    }

    private func connect(_ repository: CellarRepository) throws {
        try repository.beginSync(accountID: "owner", serverURL: URL(string: "https://cork.example")!)
    }

    private func acceptNext(_ repository: CellarRepository, version: Int) throws -> SyncOperation {
        let operation = try XCTUnwrap(repository.nextSyncOperation())
        try repository.acknowledgeSync(operation, change: SyncChange(bottleID: operation.bottleID, version: version,
                                                                   bottle: operation.action.bottle, cursor: version))
        return operation
    }

    func testOfflineEditsKeepOrderAndNewerProjectionWhenAcknowledgingOlderRequest() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        let entry = try create(repository)
        try connect(repository)
        _ = try acceptNext(repository, version: 1)
        try repository.updateBottle(bottleID: entry.id, storageLocation: "Rack A", note: "A", remainingPercent: 100)
        let first = try XCTUnwrap(repository.nextSyncOperation())
        try repository.updateBottle(bottleID: entry.id, storageLocation: "Rack A", note: "B", remainingPercent: 100)
        XCTAssertEqual(first.baseVersion, 1)
        XCTAssertEqual(first, try repository.nextSyncOperation())
        try repository.acknowledgeSync(first, change: SyncChange(bottleID: entry.id, version: 2, bottle: first.action.bottle, cursor: 2))
        XCTAssertEqual(try repository.fetchEntries().first?.note, "B")
        let second = try XCTUnwrap(repository.nextSyncOperation())
        XCTAssertEqual(second.baseVersion, 2)
        XCTAssertEqual(second.action.bottle?.note, "B")
        XCTAssertEqual(try repository.syncState()?.cursor, 0, "Acknowledging a write must not skip intervening remote changes")
    }

    func testMigrationSnapshotRemainsFixedWhileEditingAndDeleting() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        let a = try create(repository, name: "A"), b = try create(repository, name: "B")
        try connect(repository)
        let snapshot = try XCTUnwrap(repository.syncState()).pending
        try repository.updateBottle(bottleID: a.id, storageLocation: "Rack B", note: "During migration", remainingPercent: 100)
        try repository.deleteEntry(bottleID: b.id)
        let state = try XCTUnwrap(repository.syncState())
        XCTAssertEqual(Array(state.pending.prefix(2)), snapshot)
        XCTAssertEqual(state.pending.count, 4)
        XCTAssertFalse(state.migrationComplete)
        for revision in 1...4 { _ = try acceptNext(repository, version: revision) }
        XCTAssertTrue(try XCTUnwrap(repository.syncState()).migrationComplete)
        XCTAssertEqual(try repository.fetchEntries().count, 1)
        XCTAssertEqual(try repository.fetchEntries().first?.note, "During migration")
    }

    func testApplyingRemotePagePreservesLocalOnlyFieldsAndDoesNotEchoChanges() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        let entry = try create(repository)
        try connect(repository)
        let original = try XCTUnwrap(repository.exportSyncBottle(entry.id))
        var remote = original
        let operation = try XCTUnwrap(repository.nextSyncOperation())
        try repository.acknowledgeSync(operation, change: SyncChange(bottleID: entry.id, version: 1, bottle: remote, cursor: 1))
        remote.note = "From ChatGPT"
        let page = SyncPage(changes: [SyncChange(bottleID: entry.id, version: 1, bottle: original, cursor: 1),
                                      SyncChange(bottleID: entry.id, version: 2, bottle: remote, cursor: 2)], nextCursor: 2, until: 2, hasMore: false)
        try repository.receiveSyncPage(page)
        let saved = try XCTUnwrap(repository.fetchEntries().first)
        XCTAssertEqual(saved.note, "From ChatGPT")
        XCTAssertEqual(saved.purchasePrice, 3500)
        XCTAssertEqual(saved.ocrRawText, "Private OCR")
        XCTAssertNotNil(saved.sourceImageAssetID)
        XCTAssertTrue(try XCTUnwrap(repository.syncState()).pending.isEmpty)
        let json = String(decoding: try SyncCodec.encoder().encode(remote), as: UTF8.self)
        XCTAssertFalse(json.contains("purchasePrice")); XCTAssertFalse(json.contains("ocrRawText")); XCTAssertFalse(json.contains("sourceImageAssetID"))
    }

    func testMalformedOrUncommittedPageNeverAdvancesCursor() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        try connect(repository)
        XCTAssertThrowsError(try repository.receiveSyncPage(SyncPage(changes: [], nextCursor: 10, until: 10, hasMore: false)))
        XCTAssertEqual(try repository.syncState()?.cursor, 0)
        XCTAssertThrowsError(try repository.receiveSyncPage(SyncPage(changes: [], nextCursor: 0, until: 10, hasMore: true)))
        XCTAssertEqual(try repository.syncState()?.cursor, 0)
    }

    func testSaveFailureRollsBackCursorAndVisibleDataTogether() throws {
        enum Failure: Error { case disk }
        var shouldFail = false
        let container = try container()
        let repository = CellarRepository(context: container.mainContext, commitContext: { context in
            if shouldFail { throw Failure.disk }; try context.save()
        })
        let entry = try create(repository)
        try connect(repository)
        _ = try acceptNext(repository, version: 1)
        var remote = try XCTUnwrap(repository.exportSyncBottle(entry.id)); remote.note = "Remote"
        shouldFail = true
        XCTAssertThrowsError(try repository.receiveSyncPage(SyncPage(changes: [SyncChange(bottleID: entry.id, version: 1, bottle: remote, cursor: 1)], nextCursor: 1, until: 1, hasMore: false)))
        XCTAssertEqual(try repository.syncState()?.cursor, 0)
        XCTAssertNil(try repository.fetchEntries().first?.note)
        XCTAssertNotNil(try repository.fetchEntries().first?.sourceImageAssetID)
    }

    func testAccountSwitchIsRejectedWithoutTransmittingExistingData() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        _ = try create(repository)
        try connect(repository)
        XCTAssertThrowsError(try repository.beginSync(accountID: "other-owner", serverURL: URL(string: "https://cork.example")!))
        XCTAssertEqual(try repository.syncState()?.accountID, "owner")
    }

    func testV1MigrationPreservesDataAndFrozenRequestAcrossStoreReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("cellar.store")
        let id: UUID = try autoreleasepool {
            let v1 = try container(url: url, v1: true)
            return try create(CellarRepository(context: v1.mainContext)).id
        }
        let request: SyncOperation = try autoreleasepool {
            let v2 = try container(url: url)
            let repository = CellarRepository(context: v2.mainContext)
            XCTAssertEqual(try repository.fetchEntries().first?.id, id)
            try connect(repository)
            return try XCTUnwrap(repository.nextSyncOperation())
        }
        let reopened = try container(url: url)
        let repository = CellarRepository(context: reopened.mainContext)
        XCTAssertEqual(try repository.nextSyncOperation(), request)
        XCTAssertEqual(try repository.fetchEntries().first?.purchasePrice, 3500)
    }

    func testCoordinatorIncludesEditMadeWhileInitialUploadIsInFlight() async throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        let entry = try create(repository)
        try connect(repository)
        let transport = InterleavingSyncTransport {
            try repository.updateBottle(bottleID: entry.id, storageLocation: "Rack A", note: "While sending", remainingPercent: 100)
        }
        let coordinator = SyncCoordinator(repository: repository)
        await coordinator.synchronize(using: transport)
        XCTAssertNil(coordinator.errorMessage)
        XCTAssertEqual(try repository.fetchEntries().first?.note, "While sending")
        XCTAssertTrue(try XCTUnwrap(repository.syncState()).pending.isEmpty)
        XCTAssertEqual(try repository.syncState()?.cursor, 2)
        let sent = await transport.requests
        XCTAssertEqual(sent.map(\.baseVersion), [0, 1])
    }

    func testExternalConflictRetainsLocalEditUntilExplicitResolution() throws {
        let container = try container(), repository = CellarRepository(context: container.mainContext)
        let entry = try create(repository)
        try connect(repository)
        _ = try acceptNext(repository, version: 1)
        try repository.updateBottle(bottleID: entry.id, storageLocation: "Rack A", note: "Local", remainingPercent: 100)
        let originalRequest = try XCTUnwrap(repository.nextSyncOperation())
        var remote = try XCTUnwrap(originalRequest.action.bottle); remote.note = "ChatGPT"
        try repository.recordSyncConflict(SyncChange(bottleID: entry.id, version: 2, bottle: remote, cursor: 2))
        XCTAssertNil(try repository.nextSyncOperation())
        XCTAssertEqual(try repository.fetchEntries().first?.note, "Local")
        try repository.resolveSyncConflict(bottleID: entry.id, keepLocal: true)
        let resolved = try XCTUnwrap(repository.nextSyncOperation())
        XCTAssertNotEqual(resolved.operationID, originalRequest.operationID)
        XCTAssertEqual(resolved.baseVersion, 2)
        XCTAssertEqual(resolved.action.bottle?.note, "Local")
    }

    func testFailedDeleteKeepsImageAndUnsentQueueUnchanged() throws {
        enum Failure: Error { case disk }
        var shouldFail = false
        let container = try container()
        let repository = CellarRepository(context: container.mainContext, commitContext: { context in
            if shouldFail { throw Failure.disk }; try context.save()
        })
        let entry = try create(repository)
        try connect(repository)
        let pending = try XCTUnwrap(repository.syncState()).pending
        shouldFail = true
        XCTAssertThrowsError(try repository.deleteEntry(bottleID: entry.id))
        XCTAssertEqual(try repository.fetchEntries().first?.id, entry.id)
        XCTAssertEqual(try repository.syncState()?.pending, pending)
        XCTAssertEqual(try repository.loadImageData(for: XCTUnwrap(entry.sourceImageAssetID)), Data([1, 2, 3]))
    }
}

private actor InterleavingSyncTransport: SyncTransport {
    var requests: [SyncOperation] = []
    var log: [SyncChange] = []
    let duringFirstSend: @MainActor @Sendable () throws -> Void

    init(duringFirstSend: @escaping @MainActor @Sendable () throws -> Void) { self.duringFirstSend = duringFirstSend }

    func send(_ operation: SyncOperation) async throws -> SyncChange {
        if requests.isEmpty { try await duringFirstSend() }
        requests.append(operation)
        let result = SyncChange(bottleID: operation.bottleID, version: log.count + 1, bottle: operation.action.bottle, cursor: log.count + 1)
        log.append(result)
        return result
    }

    func changes(after: Int, until: Int?) async throws -> SyncPage {
        let upper = until ?? log.count
        return SyncPage(changes: log.filter { $0.cursor > after && $0.cursor <= upper }, nextCursor: upper, until: upper, hasMore: false)
    }

    func acknowledge(cursor: Int) async throws {}
}

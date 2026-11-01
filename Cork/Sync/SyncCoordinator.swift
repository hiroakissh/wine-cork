import Foundation
import SwiftUI

@MainActor
final class SyncCoordinator: ObservableObject {
    @Published private(set) var isSyncing = false
    @Published private(set) var errorMessage: String?
    private let repository: CellarRepository
    private var rerunRequested = false
    var didChange: (() -> Void)?

    init(repository: CellarRepository) { self.repository = repository }

    func synchronize(using transport: any SyncTransport) async {
        guard !isSyncing else { rerunRequested = true; return }
        isSyncing = true; errorMessage = nil
        defer { isSyncing = false; didChange?() }
        do {
            repeat {
                rerunRequested = false
                while let operation = try repository.nextSyncOperation() {
                    try Task.checkCancellation()
                    do {
                        let result = try await transport.send(operation)
                        try repository.acknowledgeSync(operation, change: result)
                    } catch let conflict as SyncConflict {
                        guard conflict.current.bottleID == operation.bottleID else { throw SyncError.invalidResponse }
                        try repository.recordSyncConflict(conflict.current)
                    }
                    didChange?()
                }
                var hasMore: Bool
                repeat {
                    try Task.checkCancellation()
                    guard let state = try repository.syncState() else { return }
                    let page = try await transport.changes(after: state.cursor, until: state.pageUntil)
                    try repository.receiveSyncPage(page)
                    hasMore = page.hasMore
                } while hasMore
                if let state = try repository.syncState() { try await transport.acknowledge(cursor: state.cursor) }
            } while rerunRequested
        } catch is CancellationError {
            // Frozen requests and cursors remain durable for the next attempt.
        } catch { errorMessage = error.localizedDescription }
    }
}

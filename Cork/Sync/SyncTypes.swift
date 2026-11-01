import Foundation

enum SyncCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
            }
            return date
        }
        return decoder
    }
}

struct SyncTasting: Codable, Equatable, Sendable {
    var id: UUID
    var tastedAt: Date
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
    var servingTemperatureCelsius: Double?
    var openedHoursBeforeTasting: Double?
}

struct SyncPairing: Codable, Equatable, Sendable {
    var id: UUID
    var tastingID: UUID?
    var dishName: String
    var dishCategory: String?
    var score: Int
    var note: String?
}

struct SyncEvent: Codable, Equatable, Sendable {
    var id: UUID
    var fromState: BottleLifecycleState?
    var toState: BottleLifecycleState
    var occurredAt: Date
    var note: String?
}

/// This DTO deliberately excludes local images, prices, OCR and filesystem paths.
struct SyncBottle: Codable, Equatable, Sendable {
    var id: UUID
    var wineID: UUID
    var cellarID: UUID
    var name: String
    var producer: String?
    var region: String?
    var country: String?
    var grapeVarieties: [String]
    var vintage: Int?
    var wineType: WineType
    var volumeML: Int?
    var alcoholPercent: Double?
    var lifecycleState: BottleLifecycleState
    var storageLocation: String?
    var acquiredAt: Date?
    var openedAt: Date?
    var finishedAt: Date?
    var remainingPercent: Int?
    var note: String?
    var bottleShape: BottleShape
    var createdAt: Date
    var updatedAt: Date
    var tastings: [SyncTasting]
    var pairings: [SyncPairing]
    var events: [SyncEvent]

    var key: String { id.uuidString.lowercased() }
}

struct SyncChange: Codable, Equatable, Sendable {
    var bottleID: UUID
    var version: Int
    var bottle: SyncBottle?
    var cursor: Int
    var key: String { bottleID.uuidString.lowercased() }
}

struct SyncPage: Codable, Sendable {
    var changes: [SyncChange]
    var nextCursor: Int
    var until: Int
    var hasMore: Bool
}

struct SyncAction: Codable, Equatable, Sendable {
    var kind: String
    var bottle: SyncBottle?
}

struct SyncOperation: Codable, Equatable, Sendable {
    var operationID: UUID
    var bottleID: UUID
    var baseVersion: Int
    var action: SyncAction
}

struct PendingSyncOperation: Codable, Equatable, Identifiable, Sendable {
    var id: UUID = UUID()
    var sequence: Int
    var bottleID: UUID
    var action: SyncAction
    var frozenRequest: SyncOperation?
    var key: String { bottleID.uuidString.lowercased() }
}

struct SyncState: Codable, Sendable {
    var accountID: String
    var serverURL: URL
    var cursor = 0
    var pageUntil: Int?
    var baseline: [String: SyncChange] = [:]
    var pending: [PendingSyncOperation] = []
    var conflicts: [String: SyncChange] = [:]
    var snapshotOperationIDs: [UUID] = []
    var migrationBoundary: Int?
    var nextSequence = 1
    var lastSyncedAt: Date?

    var migrationComplete: Bool {
        guard let migrationBoundary else { return false }
        return !pending.contains { $0.sequence <= migrationBoundary }
    }

    mutating func enqueue(_ action: SyncAction, bottleID: UUID, snapshot: Bool = false) {
        let operation = PendingSyncOperation(sequence: nextSequence, bottleID: bottleID, action: action)
        nextSequence += 1
        pending.append(operation)
        if snapshot { snapshotOperationIDs.append(operation.id) }
    }

    mutating func finishSnapshotIfNeeded() {
        if snapshotOperationIDs.isEmpty, migrationBoundary == nil { migrationBoundary = nextSequence - 1 }
    }

    func projection(for key: String) -> SyncBottle? {
        if let operation = pending.last(where: { $0.key == key }) { return operation.action.bottle }
        return baseline[key]?.bottle
    }
}

enum SyncError: LocalizedError, Equatable {
    case accountMismatch
    case invalidResponse
    case authorizationRequired
    case server(String)

    var errorDescription: String? {
        switch self {
        case .accountMismatch: "この端末のデータは別のアカウントまたはサーバーに接続済みです。同じ接続先でログインしてください。"
        case .invalidResponse: "同期サーバーの応答を確認できませんでした。"
        case .authorizationRequired: "再度ログインして同期してください。"
        case .server(let code): "同期を完了できませんでした（\(code)）。未送信の変更は保存されています。"
        }
    }
}

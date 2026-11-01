import Foundation
import SwiftData

@MainActor
extension CellarRepository {
    func syncState() throws -> SyncState? {
        guard let journal = try context.fetch(FetchDescriptor<SyncJournalRecord>()).first else { return nil }
        return try SyncCodec.decoder().decode(SyncState.self, from: journal.payload)
    }

    func beginSync(accountID: String, serverURL: URL) throws {
        if let state = try syncState() {
            guard state.accountID == accountID, state.serverURL == serverURL else { throw SyncError.accountMismatch }
            return
        }
        var state = SyncState(accountID: accountID, serverURL: serverURL)
        // No await between snapshot capture and journal persistence: local mutations
        // are serialized on MainActor and all later saves record their changes.
        for entry in try fetchEntries() {
            if let bottle = try exportSyncBottle(entry.id) {
                state.enqueue(SyncAction(kind: "import", bottle: bottle), bottleID: bottle.id, snapshot: true)
            }
        }
        state.finishSnapshotIfNeeded()
        try saveSyncState(state)
    }

    func saveLocalChanges(_ ids: Set<UUID>) throws {
        do {
            if var state = try syncState() {
                for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                    let key = id.uuidString.lowercased()
                    let bottle = try exportSyncBottle(id)
                    if bottle == state.projection(for: key) { continue }
                    let known = state.baseline[key] != nil || state.pending.contains { $0.key == key }
                    state.enqueue(SyncAction(kind: bottle == nil ? "delete" : known ? "replace" : "create", bottle: bottle), bottleID: id)
                }
                try writeSyncState(state)
            }
            try commitContext(context)
        } catch { context.rollback(); throw error }
    }

    func nextSyncOperation() throws -> SyncOperation? {
        guard var state = try syncState(), let index = state.pending.firstIndex(where: { state.conflicts[$0.key] == nil }) else { return nil }
        if let request = state.pending[index].frozenRequest { return request }
        let pending = state.pending[index]
        let request = SyncOperation(operationID: pending.id, bottleID: pending.bottleID,
                                    baseVersion: state.baseline[pending.key]?.version ?? 0, action: pending.action)
        state.pending[index].frozenRequest = request
        try saveSyncState(state)
        return request
    }

    func acknowledgeSync(_ operation: SyncOperation, change: SyncChange) throws {
        guard var state = try syncState(), change.bottleID == operation.bottleID,
              change.version > 0, change.cursor >= change.version,
              change.bottle == nil || change.bottle?.id == operation.bottleID,
              state.pending.contains(where: { $0.id == operation.operationID }) else { throw SyncError.invalidResponse }
        state.pending.removeAll { $0.id == operation.operationID }
        state.snapshotOperationIDs.removeAll { $0 == operation.operationID }
        if change.version >= (state.baseline[change.key]?.version ?? 0) { state.baseline[change.key] = change }
        state.finishSnapshotIfNeeded()
        try saveSyncState(state, applying: [change.key])
    }

    func receiveSyncPage(_ page: SyncPage) throws {
        guard var state = try syncState(), page.nextCursor >= state.cursor, page.nextCursor <= page.until,
              state.pageUntil == nil || state.pageUntil == page.until,
              !page.hasMore || page.nextCursor > state.cursor else { throw SyncError.invalidResponse }
        var previous = state.cursor
        for change in page.changes {
            guard change.cursor == previous + 1, change.cursor <= page.nextCursor, change.version == change.cursor,
                  change.bottle == nil || change.bottle?.id == change.bottleID else { throw SyncError.invalidResponse }
            previous = change.cursor
            if change.version >= (state.baseline[change.key]?.version ?? 0) {
                state.baseline[change.key] = change
                if state.conflicts[change.key] != nil { state.conflicts[change.key] = change }
            }
        }
        guard page.nextCursor == previous, page.hasMore || page.nextCursor == page.until else { throw SyncError.invalidResponse }
        state.cursor = page.nextCursor
        state.pageUntil = page.hasMore ? page.until : nil
        state.lastSyncedAt = Date()
        try saveSyncState(state, applying: Set(page.changes.map(\.key)))
    }

    func recordSyncConflict(_ change: SyncChange) throws {
        guard var state = try syncState() else { return }
        state.conflicts[change.key] = change
        if change.version >= (state.baseline[change.key]?.version ?? 0) { state.baseline[change.key] = change }
        try saveSyncState(state)
    }

    func resolveSyncConflict(bottleID: UUID, keepLocal: Bool) throws {
        guard var state = try syncState() else { return }
        let key = bottleID.uuidString.lowercased()
        guard let remote = state.conflicts[key] else { return }
        let local = state.projection(for: key)
        if keepLocal, local != nil, remote.bottle == nil { throw SyncError.server("DELETED_ON_SERVER") }
        let removed = Set(state.pending.filter { $0.key == key }.map(\.id))
        state.pending.removeAll { $0.key == key }
        state.snapshotOperationIDs.removeAll { removed.contains($0) }
        state.baseline[key] = remote
        state.conflicts.removeValue(forKey: key)
        if keepLocal { state.enqueue(SyncAction(kind: local == nil ? "delete" : "replace", bottle: local), bottleID: bottleID) }
        state.finishSnapshotIfNeeded()
        try saveSyncState(state, applying: [key])
    }

    private func writeSyncState(_ state: SyncState) throws {
        let data = try SyncCodec.encoder().encode(state)
        if let journal = try context.fetch(FetchDescriptor<SyncJournalRecord>()).first { journal.payload = data }
        else { context.insert(SyncJournalRecord(payload: data)) }
    }

    private func saveSyncState(_ state: SyncState, applying keys: Set<String> = []) throws {
        do {
            for key in keys {
                guard let id = UUID(uuidString: key) else { throw SyncError.invalidResponse }
                try applySyncBottle(state.projection(for: key), id: id)
            }
            try writeSyncState(state)
            try commitContext(context)
        } catch { context.rollback(); throw error }
    }

    func exportSyncBottle(_ id: UUID) throws -> SyncBottle? {
        guard let bottle = try context.fetch(FetchDescriptor<WineBottleRecord>(predicate: #Predicate { $0.id == id })).first else { return nil }
        let wineID = bottle.wineID
        guard let wine = try context.fetch(FetchDescriptor<WineRecord>(predicate: #Predicate { $0.id == wineID })).first else { return nil }
        let tastings = try fetchTastings(for: id).map { t in
            SyncTasting(id: t.id, tastedAt: t.tastedAt, rating: t.rating, acidity: t.acidity, sweetness: t.sweetness,
                        tannin: t.tannin, body: t.body, alcohol: t.alcohol, finish: t.finish,
                        aromaTags: t.aromaTags, palateTags: t.palateTags, note: t.note,
                        servingTemperatureCelsius: t.servingTemperatureCelsius, openedHoursBeforeTasting: t.openedHoursBeforeTasting)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let pairings = try context.fetch(FetchDescriptor<PairingRecord>(predicate: #Predicate { $0.bottleID == id })).map {
            SyncPairing(id: $0.id, tastingID: $0.tastingID, dishName: $0.dishName, dishCategory: $0.dishCategory, score: $0.score, note: $0.note)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let events = try context.fetch(FetchDescriptor<BottleLifecycleEventRecord>(predicate: #Predicate { $0.bottleID == id })).map {
            SyncEvent(id: $0.id, fromState: $0.fromStateRawValue.flatMap(BottleLifecycleState.init(rawValue:)), toState: BottleLifecycleState(rawValue: $0.toStateRawValue) ?? .owned, occurredAt: $0.occurredAt, note: $0.note)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        let value = SyncBottle(id: id, wineID: wineID, cellarID: bottle.cellarID, name: wine.name, producer: wine.producer,
                          region: wine.region, country: wine.country, grapeVarieties: wine.grapeVarieties, vintage: wine.vintage,
                          wineType: wine.wineType, volumeML: wine.volumeML, alcoholPercent: wine.alcoholPercent,
                          lifecycleState: bottle.lifecycleState, storageLocation: bottle.storageLocation,
                          acquiredAt: bottle.acquiredAt, openedAt: bottle.openedAt, finishedAt: bottle.finishedAt,
                          remainingPercent: bottle.remainingPercent, note: bottle.note, bottleShape: bottle.bottleShape,
                          createdAt: bottle.createdAt, updatedAt: bottle.updatedAt, tastings: tastings, pairings: pairings, events: events)
        // Match wire precision so decoding a durable queue does not create false edits.
        return try SyncCodec.decoder().decode(SyncBottle.self, from: SyncCodec.encoder().encode(value))
    }

    private func applySyncBottle(_ value: SyncBottle?, id: UUID) throws {
        let oldBottle = try context.fetch(FetchDescriptor<WineBottleRecord>(predicate: #Predicate { $0.id == id })).first
        let oldTastings = try fetchTastings(for: id)
        let oldPairings = try context.fetch(FetchDescriptor<PairingRecord>(predicate: #Predicate { $0.bottleID == id }))
        let oldEvents = try context.fetch(FetchDescriptor<BottleLifecycleEventRecord>(predicate: #Predicate { $0.bottleID == id }))
        guard let value else {
            oldTastings.forEach(context.delete); oldPairings.forEach(context.delete); oldEvents.forEach(context.delete)
            if let oldBottle { context.delete(oldBottle) }
            // Media files are retained; do not delete filesystem data before a DB commit.
            return
        }
        let cellarID = value.cellarID
        if try context.fetch(FetchDescriptor<LocalCellarRecord>(predicate: #Predicate { $0.id == cellarID })).isEmpty {
            context.insert(LocalCellarRecord(id: cellarID, name: "Cork"))
        }
        let wineID = value.wineID
        let existingWine = try context.fetch(FetchDescriptor<WineRecord>(predicate: #Predicate { $0.id == wineID })).first
        let wine = existingWine ?? WineRecord(id: wineID, name: value.name)
        if existingWine == nil { context.insert(wine) }
        wine.name = value.name; wine.producer = value.producer; wine.region = value.region; wine.country = value.country
        wine.grapeVarieties = value.grapeVarieties; wine.vintage = value.vintage; wine.wineType = value.wineType
        wine.volumeML = value.volumeML; wine.alcoholPercent = value.alcoholPercent; wine.updatedAt = value.updatedAt
        let bottle = oldBottle ?? WineBottleRecord(id: id, cellarID: cellarID, wineID: wineID)
        if oldBottle == nil { context.insert(bottle) }
        bottle.wineID = wineID; bottle.cellarID = cellarID
        bottle.lifecycleState = value.lifecycleState; bottle.storageLocation = value.storageLocation
        bottle.acquiredAt = value.acquiredAt; bottle.openedAt = value.openedAt; bottle.finishedAt = value.finishedAt
        bottle.remainingPercent = value.remainingPercent; bottle.note = value.note; bottle.bottleShape = value.bottleShape
        bottle.createdAt = value.createdAt; bottle.updatedAt = value.updatedAt
        let tastingIDs = Set(value.tastings.map(\.id)), pairingIDs = Set(value.pairings.map(\.id)), eventIDs = Set(value.events.map(\.id))
        for old in oldTastings where !tastingIDs.contains(old.id) { context.delete(old) }
        for old in oldPairings where !pairingIDs.contains(old.id) { context.delete(old) }
        for old in oldEvents where !eventIDs.contains(old.id) { context.delete(old) }
        for t in value.tastings {
            let draft = TastingDraft(rating: t.rating, acidity: t.acidity, sweetness: t.sweetness, tannin: t.tannin,
                                    body: t.body, alcohol: t.alcohol, finish: t.finish, aromaTags: t.aromaTags,
                                    palateTags: t.palateTags, note: t.note, tastedAt: t.tastedAt,
                                    servingTemperatureCelsius: t.servingTemperatureCelsius, openedHoursBeforeTasting: t.openedHoursBeforeTasting)
            if let old = oldTastings.first(where: { $0.id == t.id }) {
                old.tastedAt = t.tastedAt; old.rating = t.rating; old.acidity = t.acidity; old.sweetness = t.sweetness
                old.tannin = t.tannin; old.body = t.body; old.alcohol = t.alcohol; old.finish = t.finish
                old.aromaTags = t.aromaTags; old.palateTags = t.palateTags; old.note = t.note
                old.servingTemperatureCelsius = t.servingTemperatureCelsius; old.openedHoursBeforeTasting = t.openedHoursBeforeTasting
            } else { context.insert(TastingSessionRecord(id: t.id, bottleID: id, draft: draft)) }
        }
        for p in value.pairings {
            if let old = oldPairings.first(where: { $0.id == p.id }) {
                old.tastingID = p.tastingID; old.dishName = p.dishName; old.dishCategory = p.dishCategory; old.score = p.score; old.note = p.note
            } else {
                context.insert(PairingRecord(id: p.id, tastingID: p.tastingID, bottleID: id,
                    draft: PairingDraft(dishName: p.dishName, dishCategory: p.dishCategory, score: p.score, note: p.note)))
            }
        }
        for event in value.events {
            if let old = oldEvents.first(where: { $0.id == event.id }) {
                old.fromStateRawValue = event.fromState?.rawValue; old.toStateRawValue = event.toState.rawValue
                old.occurredAt = event.occurredAt; old.note = event.note
            } else { context.insert(BottleLifecycleEventRecord(id: event.id, bottleID: id, from: event.fromState, to: event.toState, occurredAt: event.occurredAt, note: event.note)) }
        }
        bottle.tastingCount = value.tastings.count
        bottle.lastTastedAt = value.tastings.map(\.tastedAt).max()
        let ratings = value.tastings.compactMap(\.rating)
        bottle.ratingSummary = ratings.isEmpty ? nil : Double(ratings.reduce(0, +)) / Double(ratings.count)
        bottle.tags = Array(Set(value.tastings.flatMap { $0.aromaTags + $0.palateTags })).sorted()
    }
}

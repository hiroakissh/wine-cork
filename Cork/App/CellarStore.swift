import Foundation
import SwiftUI

@MainActor
final class CellarStore: ObservableObject {
    let repository: CellarRepository
    @Published private(set) var entries: [CellarEntry] = []
    @Published private(set) var profile = TasteProfile(tastingCount: 0, averageAcidity: nil, averageSweetness: nil, averageTannin: nil, averageBody: nil, varianceAcidity: nil, varianceSweetness: nil, varianceTannin: nil, varianceBody: nil, favoriteTags: [], pairingCategories: [])
    @Published var searchText = ""
    @Published var lifecycleFilter: BottleLifecycleState?
    @Published var wineTypeFilter: WineType?
    @Published var sort: CellarSort = .updated
    @Published var errorMessage: String?
    @Published private(set) var isLoading = false

    init(repository: CellarRepository) {
        self.repository = repository
        refresh()
    }

    func refresh() {
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try repository.ensureDefaultCellar()
            entries = try repository.fetchEntries(searchText: searchText, lifecycle: lifecycleFilter, wineType: wineTypeFilter, sort: sort)
            profile = try repository.tasteProfile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func create(wine: WineDraft, bottle: BottleDraft, imageData: Data?, labelImageData: Data? = nil, bottleCutoutImageData: Data? = nil) -> Bool {
        do {
            _ = try repository.createEntry(wineDraft: wine, bottleDraft: bottle, imageData: imageData, labelImageData: labelImageData, bottleCutoutImageData: bottleCutoutImageData)
            refresh()
            return true
        } catch {
            errorMessage = "ワインを保存できませんでした。"
            return false
        }
    }

    func changeLifecycle(for id: UUID, to state: BottleLifecycleState) {
        do {
            try repository.updateLifecycle(bottleID: id, to: state)
            refresh()
        } catch {
            errorMessage = "状態を更新できませんでした。"
        }
    }

    func update(bottleID: UUID, storageLocation: String?, note: String?, remainingPercent: Int?) {
        do {
            try repository.updateBottle(bottleID: bottleID, storageLocation: storageLocation, note: note, remainingPercent: remainingPercent)
            refresh()
        } catch {
            errorMessage = "変更を保存できませんでした。"
        }
    }

    func addTasting(to id: UUID, draft: TastingDraft) {
        do {
            try repository.addTasting(to: id, draft: draft)
            refresh()
        } catch {
            errorMessage = "テイスティングを保存できませんでした。"
        }
    }

    func addPairing(to id: UUID, draft: PairingDraft) {
        do {
            try repository.addPairing(to: id, draft: draft)
            refresh()
        } catch {
            errorMessage = "ペアリングを保存できませんでした。"
        }
    }

    func delete(id: UUID) {
        do {
            try repository.deleteEntry(bottleID: id)
            refresh()
        } catch {
            errorMessage = "ワインを削除できませんでした。"
        }
    }

    func exportArchiveData() throws -> Data {
        try repository.exportArchiveData()
    }

    @discardableResult
    func importArchive(data: Data) throws -> CorkArchiveImportResult {
        let result = try repository.importArchiveData(data)
        refresh()
        return result
    }
}

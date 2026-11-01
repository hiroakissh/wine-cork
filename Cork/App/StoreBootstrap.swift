import SwiftData
import SwiftUI

/// Creates services only after the durable store has opened successfully.
@MainActor
final class StoreBootstrap: ObservableObject {
    @Published private(set) var container: ModelContainer?
    @Published private(set) var store: CellarStore?
    @Published private(set) var failed = false
    private let openStore: () throws -> ModelContainer

    init(openStore: @escaping () throws -> ModelContainer = {
        try ModelContainer(
            for: Schema(CorkSchema.models),
            migrationPlan: CorkMigrationPlan.self,
            configurations: [ModelConfiguration(isStoredInMemoryOnly: false)]
        )
    }) {
        self.openStore = openStore
    }

    func loadIfNeeded() {
        guard container == nil, !failed else { return }
        load()
    }

    func load() {
        guard container == nil else { return }
        failed = false
        do {
            let opened = try openStore()
            let loadedStore = CellarStore(repository: CellarRepository(context: opened.mainContext))
            container = opened
            store = loadedStore
        } catch {
            // Preserve the original store and pending work for recovery.
            failed = true
        }
    }
}

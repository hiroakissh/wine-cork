import SwiftData
import SwiftUI

@main
struct CorkApp: App {
    private let modelContainer: ModelContainer
    @StateObject private var store: CellarStore

    init() {
        let container: ModelContainer
        do {
            container = try ModelContainer(for: Schema(CorkSchema.models), migrationPlan: CorkMigrationPlan.self, configurations: [ModelConfiguration(isStoredInMemoryOnly: false)])
        } catch {
            container = try! ModelContainer(for: Schema(CorkSchema.models), migrationPlan: CorkMigrationPlan.self, configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        }
        modelContainer = container
        _store = StateObject(wrappedValue: CellarStore(repository: CellarRepository(context: container.mainContext)))
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .modelContainer(modelContainer)
        }
    }
}

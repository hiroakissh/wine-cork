import SwiftData
import SwiftUI

@main
struct CorkApp: App {
    @StateObject private var bootstrap = StoreBootstrap()

    var body: some Scene {
        WindowGroup {
            Group {
                if let container = bootstrap.container, let store = bootstrap.store {
                    RootView(store: store)
                        .modelContainer(container)
                } else if bootstrap.failed {
                    StorageRecoveryView { bootstrap.load() }
                } else {
                    ProgressView("データを読み込んでいます")
                }
            }
            .task { bootstrap.loadIfNeeded() }
        }
    }
}

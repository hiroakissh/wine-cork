import SwiftData
import XCTest
@testable import Cork

@MainActor
final class StoreBootstrapTests: XCTestCase {
    private enum OpenError: Error { case unavailable }

    func testFailureDoesNotCreateStoreOrRetryAutomatically() {
        var attempts = 0
        let bootstrap = StoreBootstrap {
            attempts += 1
            throw OpenError.unavailable
        }
        bootstrap.loadIfNeeded()
        bootstrap.loadIfNeeded()
        XCTAssertTrue(bootstrap.failed)
        XCTAssertNil(bootstrap.container)
        XCTAssertNil(bootstrap.store)
        XCTAssertEqual(attempts, 1)
    }

    func testExplicitRetryCanRecoverWithoutReplacingTheStore() throws {
        let container = try ModelContainer(
            for: Schema(CorkSchema.models),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]
        )
        var attempts = 0
        let bootstrap = StoreBootstrap {
            attempts += 1
            if attempts == 1 { throw OpenError.unavailable }
            return container
        }
        bootstrap.load()
        bootstrap.load()
        XCTAssertFalse(bootstrap.failed)
        XCTAssertTrue(bootstrap.container === container)
        XCTAssertNotNil(bootstrap.store)
        bootstrap.load()
        XCTAssertEqual(attempts, 2)
    }
}

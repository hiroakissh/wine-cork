import Foundation
import SwiftData

@Model
final class SyncJournalRecord {
    @Attribute(.unique) var id: String
    var payload: Data

    init(payload: Data) {
        id = "active"
        self.payload = payload
    }
}

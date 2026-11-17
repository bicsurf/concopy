import Foundation
import GRDB

public struct SnippetRestoreOrigin: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "snippet_restore_origins"
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .lowercaseString }
    public var originalId: UUID
    public var payloadHash: String
    public var restoredId: UUID

    public init(originalId: UUID, payloadHash: String, restoredId: UUID) {
        self.originalId = originalId
        self.payloadHash = payloadHash
        self.restoredId = restoredId
    }
}

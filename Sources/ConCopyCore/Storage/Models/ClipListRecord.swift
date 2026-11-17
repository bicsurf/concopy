import Foundation
import GRDB

public struct ClipListRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "clip_lists"
    // GRDB 6 uses the property; GRDB 7 requests a per-column strategy.
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .lowercaseString }

    public var id: UUID
    public var name: String
    public var sortOrder: Int
    public var isAutoStarActive: Bool
    public var sortMode: ClipSortMode
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        sortOrder: Int = 0,
        isAutoStarActive: Bool = false,
        sortMode: ClipSortMode = .updatedAtDesc,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sortOrder = sortOrder
        self.isAutoStarActive = isAutoStarActive
        self.sortMode = sortMode
        self.createdAt = createdAt
    }
}

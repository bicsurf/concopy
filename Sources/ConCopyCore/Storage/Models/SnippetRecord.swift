import Foundation
import GRDB

public struct SnippetRecord: Codable, FetchableRecord, PersistableRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "snippets"
    // GRDB 6 uses the property; GRDB 7 requests a per-column strategy.
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .lowercaseString }

    public var id: UUID
    public var shortcut: String
    public var content: String
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        shortcut: String,
        content: String,
        title: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.shortcut = shortcut
        self.content = content
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

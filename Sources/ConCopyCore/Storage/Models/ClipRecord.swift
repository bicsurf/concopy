import Foundation
import GRDB

public struct ClipRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "clips"
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString

    public var id: UUID
    public var contentHash: String
    public var plainText: String?
    public var customName: String?
    public var primaryType: ClipPrimaryType
    public var sourceAppBundleId: String?
    public var isFavorite: Bool
    public var listId: UUID?
    public var pasteCount: Int
    public var manualSortIndex: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        contentHash: String,
        plainText: String? = nil,
        customName: String? = nil,
        primaryType: ClipPrimaryType,
        sourceAppBundleId: String? = nil,
        isFavorite: Bool = false,
        listId: UUID? = nil,
        pasteCount: Int = 0,
        manualSortIndex: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.contentHash = contentHash
        self.plainText = plainText
        self.customName = customName
        self.primaryType = primaryType
        self.sourceAppBundleId = sourceAppBundleId
        self.isFavorite = isFavorite
        self.listId = listId
        self.pasteCount = pasteCount
        self.manualSortIndex = manualSortIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

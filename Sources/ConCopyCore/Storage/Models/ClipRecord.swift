import Foundation
import GRDB

public struct ClipRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "clips"
    // GRDB 6 uses the property; GRDB 7 requests a per-column strategy.
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .lowercaseString }

    @TaskLocal
    static var omitV9ColumnsDuringLegacyInsert: Bool = false

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
    public var isSensitive: Bool
    public var expiresAt: Date?

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
        updatedAt: Date = Date(),
        isSensitive: Bool = false,
        expiresAt: Date? = nil
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
        self.isSensitive = isSensitive
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        contentHash = try container.decode(String.self, forKey: .contentHash)
        plainText = try container.decodeIfPresent(String.self, forKey: .plainText)
        customName = try container.decodeIfPresent(String.self, forKey: .customName)
        primaryType = try container.decode(ClipPrimaryType.self, forKey: .primaryType)
        sourceAppBundleId = try container.decodeIfPresent(String.self, forKey: .sourceAppBundleId)
        isFavorite = try container.decode(Bool.self, forKey: .isFavorite)
        listId = try container.decodeIfPresent(UUID.self, forKey: .listId)
        pasteCount = try container.decode(Int.self, forKey: .pasteCount)
        manualSortIndex = try container.decodeIfPresent(Int.self, forKey: .manualSortIndex) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isSensitive = try container.decodeIfPresent(Bool.self, forKey: .isSensitive) ?? false
        expiresAt = try container.decodeIfPresent(Date.self, forKey: .expiresAt)
    }

    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id.uuidString.lowercased()
        container["contentHash"] = contentHash
        container["plainText"] = plainText
        container["customName"] = customName
        container["primaryType"] = primaryType.rawValue
        container["sourceAppBundleId"] = sourceAppBundleId
        container["isFavorite"] = isFavorite
        container["listId"] = listId?.uuidString.lowercased()
        container["pasteCount"] = pasteCount
        container["manualSortIndex"] = manualSortIndex
        container["createdAt"] = createdAt
        container["updatedAt"] = updatedAt
        if !Self.omitV9ColumnsDuringLegacyInsert {
            container["isSensitive"] = isSensitive
            container["expiresAt"] = expiresAt
        }
    }
}

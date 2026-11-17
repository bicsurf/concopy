import Foundation
import GRDB

public struct ClipPayloadRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    public static let databaseTableName = "clip_payloads"
    // GRDB 6 uses the property; GRDB 7 requests a per-column strategy.
    public static let databaseUUIDEncodingStrategy = DatabaseUUIDEncodingStrategy.lowercaseString
    public static func databaseUUIDEncodingStrategy(for column: String) -> DatabaseUUIDEncodingStrategy { .lowercaseString }

    public var id: UUID
    public var clipId: UUID
    public var utiType: String
    public var inlineData: Data?
    public var blobFilename: String?
    public var byteSize: Int

    public init(
        id: UUID = UUID(),
        clipId: UUID,
        utiType: String,
        inlineData: Data? = nil,
        blobFilename: String? = nil,
        byteSize: Int
    ) {
        self.id = id
        self.clipId = clipId
        self.utiType = utiType
        self.inlineData = inlineData
        self.blobFilename = blobFilename
        self.byteSize = byteSize
    }
}

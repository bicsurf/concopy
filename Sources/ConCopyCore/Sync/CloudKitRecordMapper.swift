import CloudKit
import Foundation

public struct CloudKitRecordMapper: Sendable {
    public static let clipRecordType = "Clip"
    public static let listRecordType = "ClipList"
    public static let zoneID = CKRecordZone.ID(zoneName: "ConCopyZone", ownerName: CKCurrentUserDefaultName)

    public init() {}

    // MARK: - Clip -> CKRecord
    public func makeRecord(from clip: ClipRecord) -> CKRecord {
        let recordID = CKRecord.ID(recordName: clip.id.uuidString.lowercased(), zoneID: Self.zoneID)
        let record = CKRecord(recordType: Self.clipRecordType, recordID: recordID)

        record["plainText"] = clip.plainText as CKRecordValue?
        record["customName"] = clip.customName as CKRecordValue?
        record["primaryType"] = clip.primaryType.rawValue as CKRecordValue
        record["contentHash"] = clip.contentHash as CKRecordValue
        record["isFavorite"] = (clip.isFavorite ? 1 : 0) as CKRecordValue
        record["sourceAppBundleId"] = clip.sourceAppBundleId as CKRecordValue?
        record["pasteCount"] = clip.pasteCount as CKRecordValue
        record["manualSortIndex"] = clip.manualSortIndex as CKRecordValue
        record["createdAt"] = clip.createdAt as CKRecordValue
        record["updatedAt"] = clip.updatedAt as CKRecordValue

        if let listId = clip.listId {
            record["listId"] = listId.uuidString.lowercased() as CKRecordValue
        }

        return record
    }

    // MARK: - CKRecord -> ClipRecord
    public func makeClip(from record: CKRecord) -> ClipRecord? {
        guard record.recordType == Self.clipRecordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let contentHash = record["contentHash"] as? String else {
            return nil
        }

        let plainText = record["plainText"] as? String
        let customName = record["customName"] as? String
        let rawType = record["primaryType"] as? String ?? ClipPrimaryType.text.rawValue
        let primaryType = ClipPrimaryType(rawValue: rawType) ?? .text
        let isFavoriteInt = record["isFavorite"] as? Int64 ?? 0
        let isFavorite = isFavoriteInt == 1
        let sourceApp = record["sourceAppBundleId"] as? String
        let pasteCount = Int(record["pasteCount"] as? Int64 ?? 0)
        let manualSortIndex = Int(record["manualSortIndex"] as? Int64 ?? 0)
        let createdAt = record["createdAt"] as? Date ?? record.creationDate ?? Date()
        let updatedAt = record["updatedAt"] as? Date ?? record.modificationDate ?? Date()

        let listId: UUID?
        if let listIdStr = record["listId"] as? String {
            listId = UUID(uuidString: listIdStr)
        } else {
            listId = nil
        }

        return ClipRecord(
            id: id,
            contentHash: contentHash,
            plainText: plainText,
            customName: customName,
            primaryType: primaryType,
            sourceAppBundleId: sourceApp,
            isFavorite: isFavorite,
            listId: listId,
            pasteCount: pasteCount,
            manualSortIndex: manualSortIndex,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - List -> CKRecord
    public func makeRecord(from list: ClipListRecord) -> CKRecord {
        let recordID = CKRecord.ID(recordName: list.id.uuidString.lowercased(), zoneID: Self.zoneID)
        let record = CKRecord(recordType: Self.listRecordType, recordID: recordID)

        record["name"] = list.name as CKRecordValue
        record["sortOrder"] = list.sortOrder as CKRecordValue
        record["isAutoStarActive"] = (list.isAutoStarActive ? 1 : 0) as CKRecordValue
        record["sortMode"] = list.sortMode.rawValue as CKRecordValue
        record["createdAt"] = list.createdAt as CKRecordValue

        return record
    }

    // MARK: - CKRecord -> ClipListRecord
    public func makeList(from record: CKRecord) -> ClipListRecord? {
        guard record.recordType == Self.listRecordType,
              let id = UUID(uuidString: record.recordID.recordName),
              let name = record["name"] as? String else {
            return nil
        }

        let sortOrder = Int(record["sortOrder"] as? Int64 ?? 0)
        let isAutoStarInt = record["isAutoStarActive"] as? Int64 ?? 0
        let isAutoStarActive = isAutoStarInt == 1
        let rawSortMode = record["sortMode"] as? String ?? ClipSortMode.updatedAtDesc.rawValue
        let sortMode = ClipSortMode(rawValue: rawSortMode) ?? .updatedAtDesc
        let createdAt = record["createdAt"] as? Date ?? record.creationDate ?? Date()

        return ClipListRecord(
            id: id,
            name: name,
            sortOrder: sortOrder,
            isAutoStarActive: isAutoStarActive,
            sortMode: sortMode,
            createdAt: createdAt
        )
    }
}

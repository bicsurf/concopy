import Foundation
import GRDB

public struct BackupPayloadItem: Codable, Sendable {
    public let utiType: String
    public let base64Data: String
    public let byteSize: Int

    public init(utiType: String, base64Data: String, byteSize: Int) {
        self.utiType = utiType
        self.base64Data = base64Data
        self.byteSize = byteSize
    }
}

public struct BackupClipItem: Codable, Sendable {
    public let id: UUID
    public let contentHash: String
    public let plainText: String?
    public let customName: String?
    public let primaryType: ClipPrimaryType
    public let sourceAppBundleId: String?
    public let isFavorite: Bool
    public let listId: UUID?
    public let pasteCount: Int
    public let manualSortIndex: Int
    public let createdAt: Date
    public let updatedAt: Date
    public let payloads: [BackupPayloadItem]

    public init(
        id: UUID,
        contentHash: String,
        plainText: String?,
        customName: String?,
        primaryType: ClipPrimaryType,
        sourceAppBundleId: String?,
        isFavorite: Bool,
        listId: UUID?,
        pasteCount: Int,
        manualSortIndex: Int,
        createdAt: Date,
        updatedAt: Date,
        payloads: [BackupPayloadItem]
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
        self.payloads = payloads
    }
}

public struct ConCopyArchive: Codable, Sendable {
    public let version: Int
    public let appVersion: String
    public let exportedAt: Date
    public let lists: [ClipListRecord]
    public let clips: [BackupClipItem]

    public init(
        version: Int = 1,
        appVersion: String = "1.0.0",
        exportedAt: Date = Date(),
        lists: [ClipListRecord],
        clips: [BackupClipItem]
    ) {
        self.version = version
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.lists = lists
        self.clips = clips
    }
}

public struct ArchiveManager: Sendable {
    public init() {}

    public func exportArchive(to destinationURL: URL, databaseManager: DatabaseManager) async throws {
        let lists = try databaseManager.fetchAllLists()
        let clips = try databaseManager.searchClips(query: "", limit: 100_000)

        var backupClips: [BackupClipItem] = []
        for clip in clips {
            let item: BackupClipItem = try autoreleasepool {
                let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
                var backupPayloads: [BackupPayloadItem] = []
                for payload in payloads {
                    let data = try databaseManager.loadPayloadData(for: payload)
                    backupPayloads.append(
                        BackupPayloadItem(
                            utiType: payload.utiType,
                            base64Data: data.base64EncodedString(),
                            byteSize: payload.byteSize
                        )
                    )
                }

                return BackupClipItem(
                    id: clip.id,
                    contentHash: clip.contentHash,
                    plainText: clip.plainText,
                    customName: clip.customName,
                    primaryType: clip.primaryType,
                    sourceAppBundleId: clip.sourceAppBundleId,
                    isFavorite: clip.isFavorite,
                    listId: clip.listId,
                    pasteCount: clip.pasteCount,
                    manualSortIndex: clip.manualSortIndex,
                    createdAt: clip.createdAt,
                    updatedAt: clip.updatedAt,
                    payloads: backupPayloads
                )
            }
            backupClips.append(item)
        }

        let archive = ConCopyArchive(lists: lists, clips: backupClips)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let data = try encoder.encode(archive)
        try data.write(to: destinationURL, options: .atomic)
    }

    public func importArchive(from sourceURL: URL, databaseManager: DatabaseManager) async throws {
        let (lists, clips) = try autoreleasepool { () -> ([ClipListRecord], [BackupClipItem]) in
            let data = try Data(contentsOf: sourceURL, options: .mappedIfSafe)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let archive = try decoder.decode(ConCopyArchive.self, from: data)
            return (archive.lists, archive.clips)
        }

        try await databaseManager.dbWriter.write { db in
            for list in lists {
                try list.save(db)
            }

            for clipItem in clips {
                try autoreleasepool {
                    let existing = try ClipRecord.filter(Column("contentHash") == clipItem.contentHash).fetchOne(db)
                    if var found = existing {
                        found.updatedAt = max(found.updatedAt, clipItem.updatedAt)
                        if clipItem.isFavorite {
                            found.isFavorite = true
                        }
                        if found.listId == nil {
                            found.listId = clipItem.listId
                        }
                        try found.update(db)
                        return
                    }

                    let clip = ClipRecord(
                        id: clipItem.id,
                        contentHash: clipItem.contentHash,
                        plainText: clipItem.plainText,
                        customName: clipItem.customName,
                        primaryType: clipItem.primaryType,
                        sourceAppBundleId: clipItem.sourceAppBundleId,
                        isFavorite: clipItem.isFavorite,
                        listId: clipItem.listId,
                        pasteCount: clipItem.pasteCount,
                        manualSortIndex: clipItem.manualSortIndex,
                        createdAt: clipItem.createdAt,
                        updatedAt: clipItem.updatedAt
                    )
                    try clip.insert(db)

                    for payloadItem in clipItem.payloads {
                        let payloadData = Data(base64Encoded: payloadItem.base64Data) ?? Data()
                        let payload: ClipPayloadRecord

                        if payloadData.count > 4096 {
                            let filename = try databaseManager.blobStorage.storeBlob(data: payloadData)
                            payload = ClipPayloadRecord(
                                clipId: clip.id,
                                utiType: payloadItem.utiType,
                                inlineData: nil,
                                blobFilename: filename,
                                byteSize: payloadData.count
                            )
                        } else {
                            payload = ClipPayloadRecord(
                                clipId: clip.id,
                                utiType: payloadItem.utiType,
                                inlineData: payloadData,
                                blobFilename: nil,
                                byteSize: payloadData.count
                            )
                        }
                        try payload.insert(db)
                    }
                }
            }
        }
    }
}

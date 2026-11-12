import Foundation
import GRDB

internal struct ImportClipItem: Sendable {
    let captured: CapturedClip
    let contentHash: String
    let customName: String?
    let isFavorite: Bool
    let listName: String?
    let createdAt: Date
}

internal struct ClipBatchImporter: Sendable {
    static let maxBlobSizeBytes: Int = 50 * 1024 * 1024
    static let maxTotalImportBytes: Int = 500 * 1024 * 1024
    static let maxClipCount: Int = 50_000

    private final class ListNameCache {
        private var cache: [String: UUID] = [:]
        private var maxSortOrder: Int = 0

        init(db: Database) throws {
            let lists = try ClipListRecord.fetchAll(db)
            for list in lists {
                cache[list.name.lowercased()] = list.id
                if list.sortOrder > maxSortOrder {
                    maxSortOrder = list.sortOrder
                }
            }
        }

        func listId(for rawName: String?, db: Database, createdCount: inout Int) throws -> UUID? {
            guard let rawName else { return nil }
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            let key = trimmed.lowercased()
            if let existingId = cache[key] {
                return existingId
            }

            maxSortOrder += 1
            let newList = ClipListRecord(
                name: trimmed,
                sortOrder: maxSortOrder,
                isAutoStarActive: false,
                sortMode: .updatedAtDesc,
                createdAt: Date()
            )
            try newList.insert(db)
            cache[key] = newList.id
            createdCount += 1
            return newList.id
        }
    }

    func run(
        into databaseManager: DatabaseManager,
        totalCount: Int?,
        enumerate: (_ yield: (ImportClipItem) throws -> Void) throws -> Void,
        progress: ImportProgressHandler?
    ) throws -> ImportResult {
        var result = ImportResult()
        var processedCount = 0
        var totalBytesProcessed = 0
        var newlyCreatedBlobURLs: [URL] = []

        do {
            try databaseManager.dbWriter.write { db in
                let listCache = try ListNameCache(db: db)

                try enumerate { item in
                    try Task.checkCancellation()

                    guard processedCount < Self.maxClipCount else {
                        if result.errors.count < 100 {
                            result.errors.append(ImportErrorDetail(
                                sourceIdentifier: "batch_limit",
                                message: "Raggiunto il limite massimo di \(Self.maxClipCount) elementi importabili"
                            ))
                        }
                        result.errorsCount += 1
                        return
                    }

                    processedCount += 1

                    try autoreleasepool {
                        let existing = try ClipRecord.filter(Column("contentHash") == item.contentHash).fetchOne(db)

                        let resolvedListId = try listCache.listId(for: item.listName, db: db, createdCount: &result.createdListsCount)

                        if var current = existing {
                            var didChange = false
                            if !current.isFavorite && item.isFavorite {
                                current.isFavorite = true
                                didChange = true
                            }
                            if (current.customName ?? "").isEmpty, let newName = item.customName, !newName.isEmpty {
                                current.customName = newName
                                didChange = true
                            }
                            if current.listId == nil, let targetListId = resolvedListId {
                                current.listId = targetListId
                                didChange = true
                            }

                            if didChange {
                                try current.update(db)
                            }
                            result.mergedDuplicatesCount += 1
                        } else {
                            let newClip = ClipRecord(
                                id: UUID(),
                                contentHash: item.contentHash,
                                plainText: item.captured.plainText,
                                customName: item.customName,
                                primaryType: item.captured.primaryType,
                                sourceAppBundleId: item.captured.sourceAppBundleId,
                                isFavorite: item.isFavorite,
                                listId: resolvedListId,
                                pasteCount: 0,
                                manualSortIndex: 0,
                                createdAt: item.createdAt,
                                updatedAt: item.createdAt
                            )
                            try newClip.insert(db)

                            var representations = item.captured.representations
                            if let text = item.captured.plainText, representations["public.utf8-plain-text"] == nil {
                                representations["public.utf8-plain-text"] = Data(text.utf8)
                            }

                            for (uti, data) in representations {
                                let dataCount = data.count

                                if dataCount > Self.maxBlobSizeBytes {
                                    if result.errors.count < 100 {
                                        result.errors.append(ImportErrorDetail(
                                            sourceIdentifier: item.contentHash,
                                            message: "Payload \(uti) supera la dimensione massima consentita (\(dataCount) byte)"
                                        ))
                                    }
                                    result.errorsCount += 1
                                    continue
                                }

                                totalBytesProcessed += dataCount
                                if totalBytesProcessed > Self.maxTotalImportBytes {
                                    if result.errors.count < 100 {
                                        result.errors.append(ImportErrorDetail(
                                            sourceIdentifier: "byte_limit",
                                            message: "Superato il limite di byte complessivo consentito per l'importazione"
                                        ))
                                    }
                                    result.errorsCount += 1
                                    break
                                }

                                let payload: ClipPayloadRecord
                                if dataCount > 4096 {
                                    let filename = try databaseManager.blobStorage.storeBlob(data: data)
                                    let blobURL = databaseManager.blobStorage.baseDirectoryURL.appendingPathComponent(filename)
                                    newlyCreatedBlobURLs.append(blobURL)

                                    payload = ClipPayloadRecord(
                                        clipId: newClip.id,
                                        utiType: uti,
                                        inlineData: nil,
                                        blobFilename: filename,
                                        byteSize: dataCount
                                    )
                                } else {
                                    payload = ClipPayloadRecord(
                                        clipId: newClip.id,
                                        utiType: uti,
                                        inlineData: data,
                                        blobFilename: nil,
                                        byteSize: dataCount
                                    )
                                }
                                try payload.insert(db)
                            }

                            result.importedCount += 1
                        }
                    }

                    progress?(ImportProgress(
                        processed: processedCount,
                        total: totalCount,
                        imported: result.importedCount,
                        merged: result.mergedDuplicatesCount
                    ))
                }
            }
        } catch {
            for blobURL in newlyCreatedBlobURLs {
                try? FileManager.default.removeItem(at: blobURL)
            }
            throw error
        }

        return result
    }
}

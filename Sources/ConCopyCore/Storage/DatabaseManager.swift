import CryptoKit
import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    public let dbWriter: any DatabaseWriter
    public let blobStorage: BlobStorageManager

    public init(diskDatabaseURL: URL, blobDirectoryURL: URL = BlobStorageManager.defaultBaseDirectoryURL) throws {
        let parentDir = diskDatabaseURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        }

        var config = Configuration()
        config.foreignKeysEnabled = true

        let pool = try DatabasePool(path: diskDatabaseURL.path, configuration: config)
        self.dbWriter = pool
        self.blobStorage = BlobStorageManager(baseDirectoryURL: blobDirectoryURL)

        try Self.migrator().migrate(pool)
    }

    public init(inMemoryWithBlobDirectoryURL blobDirectoryURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true

        let queue = try DatabaseQueue(configuration: config)
        self.dbWriter = queue
        self.blobStorage = BlobStorageManager(baseDirectoryURL: blobDirectoryURL)

        try Self.migrator().migrate(queue)
    }

    public static func makeFallback() -> DatabaseManager {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ConCopyFallback_\(UUID().uuidString)")
        if let db = try? DatabaseManager(inMemoryWithBlobDirectoryURL: temp) {
            return db
        }
        do {
            let q = try DatabaseQueue()
            return DatabaseManager(dbWriter: q, blobStorage: BlobStorageManager(baseDirectoryURL: temp))
        } catch {
            do {
                let path = temp.appendingPathComponent("fb.sqlite").path
                let pool = try DatabasePool(path: path)
                return DatabaseManager(dbWriter: pool, blobStorage: BlobStorageManager(baseDirectoryURL: temp))
            } catch {
                do {
                    let q = try DatabaseQueue(named: "emergency")
                    return DatabaseManager(dbWriter: q, blobStorage: BlobStorageManager(baseDirectoryURL: temp))
                } catch {
                    return makeFallback()
                }
            }
        }
    }

    public init(dbWriter: any DatabaseWriter, blobStorage: BlobStorageManager) {
        self.dbWriter = dbWriter
        self.blobStorage = blobStorage
    }

    private static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.execute(sql: """
            CREATE TABLE clip_lists (
                id TEXT PRIMARY KEY NOT NULL,
                name TEXT NOT NULL,
                sortOrder INTEGER NOT NULL DEFAULT 0,
                isAutoStarActive INTEGER NOT NULL DEFAULT 0,
                createdAt DATETIME NOT NULL
            );

            CREATE TABLE clips (
                id TEXT PRIMARY KEY NOT NULL,
                contentHash TEXT NOT NULL UNIQUE,
                plainText TEXT,
                customName TEXT,
                primaryType TEXT NOT NULL,
                sourceAppBundleId TEXT,
                isFavorite INTEGER NOT NULL DEFAULT 0,
                listId TEXT REFERENCES clip_lists(id) ON DELETE SET NULL,
                pasteCount INTEGER NOT NULL DEFAULT 0,
                createdAt DATETIME NOT NULL,
                updatedAt DATETIME NOT NULL
            );

            CREATE INDEX index_clips_on_contentHash ON clips(contentHash);
            CREATE INDEX index_clips_on_updatedAt ON clips(updatedAt DESC);
            CREATE INDEX index_clips_on_sourceAppBundleId ON clips(sourceAppBundleId);
            CREATE INDEX index_clips_on_primaryType ON clips(primaryType);
            CREATE INDEX index_clips_on_listId ON clips(listId);

            CREATE TABLE clip_payloads (
                id TEXT PRIMARY KEY NOT NULL,
                clipId TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                utiType TEXT NOT NULL,
                inlineData BLOB,
                blobFilename TEXT,
                byteSize INTEGER NOT NULL
            );

            CREATE INDEX index_clip_payloads_on_clipId ON clip_payloads(clipId);
            CREATE INDEX index_clip_payloads_on_blobFilename ON clip_payloads(blobFilename);

            CREATE VIRTUAL TABLE clips_fts USING fts5(
                plainText,
                customName,
                content='clips',
                tokenize='unicode61 remove_diacritics 2'
            );

            CREATE TRIGGER clips_ai AFTER INSERT ON clips BEGIN
                INSERT INTO clips_fts(rowid, plainText, customName) VALUES (new.rowid, new.plainText, new.customName);
            END;

            CREATE TRIGGER clips_ad AFTER DELETE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, plainText, customName) VALUES ('delete', old.rowid, old.plainText, old.customName);
            END;

            CREATE TRIGGER clips_au AFTER UPDATE ON clips BEGIN
                INSERT INTO clips_fts(clips_fts, rowid, plainText, customName) VALUES ('delete', old.rowid, old.plainText, old.customName);
                INSERT INTO clips_fts(rowid, plainText, customName) VALUES (new.rowid, new.plainText, new.customName);
            END;
            """)
        }

        migrator.registerMigration("v2_list_sorting_and_manual_order") { db in
            try db.execute(sql: """
            ALTER TABLE clip_lists ADD COLUMN sortMode TEXT NOT NULL DEFAULT 'updatedAtDesc';
            ALTER TABLE clips ADD COLUMN manualSortIndex INTEGER NOT NULL DEFAULT 0;
            CREATE INDEX index_clips_on_manualSortIndex ON clips(manualSortIndex);
            """)
        }

        return migrator
    }

    @discardableResult
    public func ingestCapturedClip(_ captured: CapturedClip) throws -> ClipRecord {
        try autoreleasepool {
            let contentHash = captured.computeContentHash()

            return try dbWriter.write { db in
                let activeAutoStarList = try ClipListRecord.filter(Column("isAutoStarActive") == true).fetchOne(db)

                if var existing = try ClipRecord.filter(Column("contentHash") == contentHash).fetchOne(db) {
                    existing.updatedAt = Date()
                    if let activeList = activeAutoStarList {
                        existing.isFavorite = true
                        existing.listId = activeList.id
                    }
                    try existing.update(db)
                    return existing
                }

                let isFavorite = activeAutoStarList != nil
                let listId = activeAutoStarList?.id
                let newClip = ClipRecord(
                    contentHash: contentHash,
                    plainText: captured.plainText,
                    customName: nil,
                    primaryType: captured.primaryType,
                    sourceAppBundleId: captured.sourceAppBundleId,
                    isFavorite: isFavorite,
                    listId: listId,
                    pasteCount: 0,
                    manualSortIndex: 0,
                    createdAt: Date(),
                    updatedAt: Date()
                )
                try newClip.insert(db)

                var representations = captured.representations
                if let text = captured.plainText, representations["public.utf8-plain-text"] == nil {
                    representations["public.utf8-plain-text"] = Data(text.utf8)
                }

                for (uti, data) in representations {
                    let payload: ClipPayloadRecord
                    if data.count > 4096 {
                        let filename = try self.blobStorage.storeBlob(data: data)
                        payload = ClipPayloadRecord(
                            clipId: newClip.id,
                            utiType: uti,
                            inlineData: nil,
                            blobFilename: filename,
                            byteSize: data.count
                        )
                    } else {
                        payload = ClipPayloadRecord(
                            clipId: newClip.id,
                            utiType: uti,
                            inlineData: data,
                            blobFilename: nil,
                            byteSize: data.count
                        )
                    }
                    try payload.insert(db)
                }

                return newClip
            }
        }
    }

    public func searchClips(
        query: String = "",
        listId: UUID? = nil,
        sourceAppBundleId: String? = nil,
        primaryType: ClipPrimaryType? = nil,
        favoritesOnly: Bool = false,
        sortMode: ClipSortMode = .updatedAtDesc,
        limit: Int = 100
    ) throws -> [ClipRecord] {
        try autoreleasepool {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

            return try dbWriter.read { db in
            var effectiveSortMode = sortMode
            if let listId, sortMode == .updatedAtDesc {
                if let list = try ClipListRecord.filter(Column("id") == listId.uuidString.lowercased()).fetchOne(db) {
                    effectiveSortMode = list.sortMode
                }
            }

            let orderClause: String
            switch effectiveSortMode {
            case .updatedAtDesc:
                orderClause = "clips.updatedAt DESC"
            case .createdAtDesc:
                orderClause = "clips.createdAt DESC"
            case .pasteCountDesc:
                orderClause = "clips.pasteCount DESC, clips.updatedAt DESC"
            case .manualOrder:
                orderClause = "clips.manualSortIndex ASC, clips.updatedAt DESC"
            }

            if trimmed.isEmpty {
                var request = ClipRecord.all()
                if let listId {
                    request = request.filter(Column("listId") == listId.uuidString.lowercased())
                }
                if let sourceAppBundleId {
                    request = request.filter(Column("sourceAppBundleId") == sourceAppBundleId)
                }
                if let primaryType {
                    request = request.filter(Column("primaryType") == primaryType.rawValue)
                }
                if favoritesOnly {
                    request = request.filter(Column("isFavorite") == true)
                }

                switch effectiveSortMode {
                case .updatedAtDesc:
                    request = request.order(Column("updatedAt").desc)
                case .createdAtDesc:
                    request = request.order(Column("createdAt").desc)
                case .pasteCountDesc:
                    request = request.order(Column("pasteCount").desc, Column("updatedAt").desc)
                case .manualOrder:
                    request = request.order(Column("manualSortIndex").asc, Column("updatedAt").desc)
                }

                return try request.limit(limit).fetchAll(db)
            }

            let words = trimmed.unicodeScalars.split { !CharacterSet.alphanumerics.contains($0) }
                .map { String($0) }
                .filter { !$0.isEmpty }

            guard !words.isEmpty else {
                let likePattern = "%\(trimmed)%"
                var fallbackSql = """
                SELECT * FROM clips
                WHERE (plainText LIKE ? OR customName LIKE ?)
                """
                var fallbackArgs: [DatabaseValueConvertible] = [likePattern, likePattern]

                if let listId {
                    fallbackSql += " AND listId = ?"
                    fallbackArgs.append(listId.uuidString.lowercased())
                }
                if let sourceAppBundleId {
                    fallbackSql += " AND sourceAppBundleId = ?"
                    fallbackArgs.append(sourceAppBundleId)
                }
                if let primaryType {
                    fallbackSql += " AND primaryType = ?"
                    fallbackArgs.append(primaryType.rawValue)
                }
                if favoritesOnly {
                    fallbackSql += " AND isFavorite = 1"
                }
                fallbackSql += " ORDER BY \(orderClause) LIMIT ?"
                fallbackArgs.append(limit)

                return try ClipRecord.fetchAll(db, sql: fallbackSql, arguments: StatementArguments(fallbackArgs))
            }

            let ftsQuery = words.map { "\"\($0)\"*" }.joined(separator: " ")

            var sql = """
            SELECT clips.* FROM clips
            JOIN clips_fts ON clips.rowid = clips_fts.rowid
            WHERE clips_fts MATCH ?
            """
            var arguments: [DatabaseValueConvertible] = [ftsQuery]

            if let listId {
                sql += " AND clips.listId = ?"
                arguments.append(listId.uuidString.lowercased())
            }
            if let sourceAppBundleId {
                sql += " AND clips.sourceAppBundleId = ?"
                arguments.append(sourceAppBundleId)
            }
            if let primaryType {
                sql += " AND clips.primaryType = ?"
                arguments.append(primaryType.rawValue)
            }
            if favoritesOnly {
                sql += " AND clips.isFavorite = 1"
            }
            sql += " ORDER BY \(orderClause) LIMIT ?"
            arguments.append(limit)

            do {
                return try ClipRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            } catch {
                let likePattern = "%\(trimmed)%"
                var fallbackSql = """
                SELECT * FROM clips
                WHERE (plainText LIKE ? OR customName LIKE ?)
                """
                var fallbackArgs: [DatabaseValueConvertible] = [likePattern, likePattern]

                if let listId {
                    fallbackSql += " AND listId = ?"
                    fallbackArgs.append(listId.uuidString.lowercased())
                }
                if let sourceAppBundleId {
                    fallbackSql += " AND sourceAppBundleId = ?"
                    fallbackArgs.append(sourceAppBundleId)
                }
                if let primaryType {
                    fallbackSql += " AND primaryType = ?"
                    fallbackArgs.append(primaryType.rawValue)
                }
                if favoritesOnly {
                    fallbackSql += " AND isFavorite = 1"
                }
                fallbackSql += " ORDER BY \(orderClause) LIMIT ?"
                fallbackArgs.append(limit)

                return try ClipRecord.fetchAll(db, sql: fallbackSql, arguments: StatementArguments(fallbackArgs))
            }
        }
    }
    }

    public func updateTextContent(clipId: UUID, newPlainText: String) throws {
        let idString = clipId.uuidString.lowercased()
        let normalized = newPlainText.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let newHash = digest.map { String(format: "%02x", $0) }.joined()
        let textData = Data(newPlainText.utf8)

        try dbWriter.write { db in
            guard var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) else {
                throw DatabaseError(message: "Clip non trovata")
            }
            clip.plainText = newPlainText
            clip.contentHash = newHash
            clip.updatedAt = Date()
            try clip.update(db)

            let textPayload = try ClipPayloadRecord.filter(
                Column("clipId") == idString && Column("utiType") == "public.utf8-plain-text"
            ).fetchOne(db)

            if var payload = textPayload {
                if let oldBlob = payload.blobFilename {
                    try? self.blobStorage.deleteBlobIfExists(filename: oldBlob)
                }
                if textData.count > 4096 {
                    let blobName = try self.blobStorage.storeBlob(data: textData)
                    payload.inlineData = nil
                    payload.blobFilename = blobName
                } else {
                    payload.inlineData = textData
                    payload.blobFilename = nil
                }
                payload.byteSize = textData.count
                try payload.update(db)
            } else {
                let newPayload: ClipPayloadRecord
                if textData.count > 4096 {
                    let blobName = try self.blobStorage.storeBlob(data: textData)
                    newPayload = ClipPayloadRecord(
                        clipId: clipId,
                        utiType: "public.utf8-plain-text",
                        inlineData: nil,
                        blobFilename: blobName,
                        byteSize: textData.count
                    )
                } else {
                    newPayload = ClipPayloadRecord(
                        clipId: clipId,
                        utiType: "public.utf8-plain-text",
                        inlineData: textData,
                        blobFilename: nil,
                        byteSize: textData.count
                    )
                }
                try newPayload.insert(db)
            }
        }
    }

    public func updateCustomName(clipId: UUID, name: String?) throws {
        let idString = clipId.uuidString.lowercased()
        let cleaned = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = (cleaned?.isEmpty ?? true) ? nil : cleaned

        try dbWriter.write { db in
            if var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) {
                clip.customName = finalName
                clip.updatedAt = Date()
                try clip.update(db)
            }
        }
    }

    public func setAutoStarList(listId: UUID?) throws {
        try dbWriter.write { db in
            try db.execute(sql: "UPDATE clip_lists SET isAutoStarActive = 0")
            if let listId {
                try db.execute(
                    sql: "UPDATE clip_lists SET isAutoStarActive = 1 WHERE id = ?",
                    arguments: [listId.uuidString.lowercased()]
                )
            }
        }
    }

    public func deleteClip(clipId: UUID) throws {
        let idString = clipId.uuidString.lowercased()
        var blobsToDelete: [String] = []

        try dbWriter.write { db in
            let payloads = try ClipPayloadRecord.filter(Column("clipId") == idString).fetchAll(db)
            let candidateBlobs = payloads.compactMap { $0.blobFilename }

            try ClipRecord.filter(Column("id") == idString).deleteAll(db)

            for filename in candidateBlobs {
                let stillUsed = try ClipPayloadRecord.filter(Column("blobFilename") == filename).fetchCount(db) > 0
                if !stillUsed {
                    blobsToDelete.append(filename)
                }
            }
        }

        for filename in blobsToDelete {
            try blobStorage.deleteBlobIfExists(filename: filename)
        }
    }

    public func loadPayloadData(for payload: ClipPayloadRecord) throws -> Data {
        if let inlineData = payload.inlineData {
            return inlineData
        }
        if let blobFilename = payload.blobFilename {
            return try blobStorage.loadBlob(filename: blobFilename)
        }
        return Data()
    }

    public func saveList(_ list: ClipListRecord) throws {
        try dbWriter.write { db in
            try list.save(db)
        }
    }

    public func createList(name: String, sortMode: ClipSortMode = .updatedAtDesc) throws -> ClipListRecord {
        try dbWriter.write { db in
            let maxSortOrder = try Int.fetchOne(db, sql: "SELECT MAX(sortOrder) FROM clip_lists") ?? 0
            let list = ClipListRecord(
                name: name,
                sortOrder: maxSortOrder + 1,
                isAutoStarActive: false,
                sortMode: sortMode
            )
            try list.insert(db)
            return list
        }
    }

    public func renameList(listId: UUID, newName: String) throws {
        let idString = listId.uuidString.lowercased()
        try dbWriter.write { db in
            if var list = try ClipListRecord.filter(Column("id") == idString).fetchOne(db) {
                list.name = newName
                try list.update(db)
            }
        }
    }

    public func updateListSortMode(listId: UUID, sortMode: ClipSortMode) throws {
        let idString = listId.uuidString.lowercased()
        try dbWriter.write { db in
            if var list = try ClipListRecord.filter(Column("id") == idString).fetchOne(db) {
                list.sortMode = sortMode
                try list.update(db)
            }
        }
    }

    public func deleteList(listId: UUID, deleteContainedClips: Bool = false) throws {
        let idString = listId.uuidString.lowercased()
        var clipsToDelete: [UUID] = []

        try dbWriter.write { db in
            if deleteContainedClips {
                let clips = try ClipRecord.filter(Column("listId") == idString).fetchAll(db)
                clipsToDelete = clips.map(\.id)
            } else {
                try db.execute(sql: "UPDATE clips SET listId = NULL WHERE listId = ?", arguments: [idString])
            }
            try ClipListRecord.filter(Column("id") == idString).deleteAll(db)
        }

        if deleteContainedClips {
            for clipId in clipsToDelete {
                try deleteClip(clipId: clipId)
            }
        }
    }

    @discardableResult
    public func clearAllHistory(preserveFavorites: Bool = true) throws -> Int {
        var clipsToDelete: [UUID] = []
        try dbWriter.read { db in
            var request = ClipRecord.all()
            if preserveFavorites {
                request = request.filter(Column("isFavorite") == false)
            }
            let clips = try request.fetchAll(db)
            clipsToDelete = clips.map(\.id)
        }

        for clipId in clipsToDelete {
            try deleteClip(clipId: clipId)
        }
        return clipsToDelete.count
    }

    public func fetchAllLists() throws -> [ClipListRecord] {
        try dbWriter.read { db in
            try ClipListRecord.order(Column("sortOrder").asc, Column("createdAt").asc).fetchAll(db)
        }
    }

    public func fetchLists() throws -> [ClipListRecord] {
        try fetchAllLists()
    }

    @discardableResult
    public func toggleFavorite(clipId: UUID) throws -> ClipRecord {
        let idString = clipId.uuidString.lowercased()
        return try dbWriter.write { db in
            guard var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) else {
                throw DatabaseError(message: "Clip non trovata")
            }
            clip.isFavorite.toggle()
            clip.updatedAt = Date()
            try clip.update(db)
            return clip
        }
    }

    @discardableResult
    public func assignClip(clipId: UUID, toListId listId: UUID?, markFavorite: Bool = true) throws -> ClipRecord {
        let idString = clipId.uuidString.lowercased()
        return try dbWriter.write { db in
            guard var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) else {
                throw DatabaseError(message: "Clip non trovata")
            }
            clip.listId = listId
            if markFavorite && listId != nil {
                clip.isFavorite = true
            }
            clip.updatedAt = Date()
            try clip.update(db)
            return clip
        }
    }

    public func reorderClipsInList(listId: UUID, orderedClipIds: [UUID]) throws {
        let listIdString = listId.uuidString.lowercased()
        try dbWriter.write { db in
            if var list = try ClipListRecord.filter(Column("id") == listIdString).fetchOne(db) {
                list.sortMode = .manualOrder
                try list.update(db)
            }
            for (index, clipId) in orderedClipIds.enumerated() {
                let clipIdString = clipId.uuidString.lowercased()
                try db.execute(
                    sql: "UPDATE clips SET manualSortIndex = ?, listId = ? WHERE id = ?",
                    arguments: [index, listIdString, clipIdString]
                )
            }
        }
    }

    public func fetchClip(id: UUID) throws -> ClipRecord? {
        let idString = id.uuidString.lowercased()
        return try dbWriter.read { db in
            try ClipRecord.filter(Column("id") == idString).fetchOne(db)
        }
    }

    public func fetchPayloads(for clipId: UUID) throws -> [ClipPayloadRecord] {
        let idString = clipId.uuidString.lowercased()
        return try dbWriter.read { db in
            try ClipPayloadRecord.filter(Column("clipId") == idString).fetchAll(db)
        }
    }

    public func fetchPayloads(forClipId clipId: UUID) throws -> [ClipPayloadRecord] {
        try fetchPayloads(for: clipId)
    }

    @discardableResult
    public func recordPasteUsage(clipId: UUID) throws -> ClipRecord? {
        let idString = clipId.uuidString.lowercased()
        return try dbWriter.write { db in
            if var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) {
                clip.pasteCount += 1
                try clip.update(db)
                return clip
            }
            return nil
        }
    }

    @discardableResult
    public func pruneClips(olderThanDays days: Int? = nil, maxCount: Int? = nil) throws -> Int {
        var clipsToDelete: [UUID] = []

        try dbWriter.read { db in
            var remainingNonFavorites: [ClipRecord] = []

            let cutoffDate: Date? = (days != nil && days! > 0)
                ? Date().addingTimeInterval(-Double(days!) * 86400.0)
                : nil

            let allNonFavorites = try ClipRecord
                .filter(Column("isFavorite") == false)
                .order(Column("updatedAt").desc, Column("createdAt").desc)
                .fetchAll(db)

            for clip in allNonFavorites {
                if let cutoff = cutoffDate, clip.createdAt < cutoff {
                    clipsToDelete.append(clip.id)
                } else {
                    remainingNonFavorites.append(clip)
                }
            }

            if let maxCount = maxCount, maxCount > 0, remainingNonFavorites.count > maxCount {
                let excess = remainingNonFavorites.suffix(from: maxCount)
                for clip in excess {
                    clipsToDelete.append(clip.id)
                }
            }
        }

        for clipId in clipsToDelete {
            try deleteClip(clipId: clipId)
        }

        return clipsToDelete.count
    }
}

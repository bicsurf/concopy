import CryptoKit
import Foundation
import GRDB

public final class DatabaseManager: Sendable {
    private static func literalSearchKey(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static let literalContains = DatabaseFunction("concopy_literal_contains", argumentCount: 2, pure: true) { values in
        autoreleasepool {
            guard let text = String.fromDatabaseValue(values[0]), let query = String.fromDatabaseValue(values[1])
            else { return false }
            return literalSearchKey(text).contains(query)
        }
    }
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

        try Self.migrator(blobStorage: blobStorage).migrate(pool)
        do { try collectMigrationBlobs() } catch { print("[ConCopy] Deferred blob cleanup: \(error)") }
    }

    /// Independent databases must own distinct blob directories; GC is scoped to one database.
    public init(inMemoryWithBlobDirectoryURL blobDirectoryURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true

        let queue = try DatabaseQueue(configuration: config)
        self.dbWriter = queue
        self.blobStorage = BlobStorageManager(baseDirectoryURL: blobDirectoryURL)

        try Self.migrator(blobStorage: blobStorage).migrate(queue)
        do { try collectMigrationBlobs() } catch { print("[ConCopy] Deferred blob cleanup: \(error)") }
    }

    public static func makeFallback() -> DatabaseManager {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "ConCopyFallback_\(UUID().uuidString)")
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

    internal static func migrator(blobStorage: BlobStorageManager) -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_initial_schema") { db in
            try db.execute(
                sql: """
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
            try db.execute(
                sql: """
                    ALTER TABLE clip_lists ADD COLUMN sortMode TEXT NOT NULL DEFAULT 'updatedAtDesc';
                    ALTER TABLE clips ADD COLUMN manualSortIndex INTEGER NOT NULL DEFAULT 0;
                    CREATE INDEX index_clips_on_manualSortIndex ON clips(manualSortIndex);
                    """)
        }

        migrator.registerMigration("v3_snippets_schema") { db in
            try db.execute(
                sql: """
                    CREATE TABLE IF NOT EXISTS snippets (
                        id TEXT PRIMARY KEY NOT NULL,
                        shortcut TEXT NOT NULL UNIQUE,
                        content TEXT NOT NULL,
                        title TEXT,
                        createdAt DATETIME NOT NULL,
                        updatedAt DATETIME NOT NULL
                    );
                    CREATE INDEX IF NOT EXISTS index_snippets_on_shortcut ON snippets(shortcut);
                    """)
        }

        migrator.registerMigration("v4_sync_change_journal") { db in
            // Previous snippet UUIDs were stored as 16-byte blobs by GRDB.
            try db.execute(
                sql: """
                    UPDATE snippets SET id = lower(substr(hex(id),1,8) || '-' || substr(hex(id),9,4) || '-' ||
                        substr(hex(id),13,4) || '-' || substr(hex(id),17,4) || '-' || substr(hex(id),21,12))
                    WHERE typeof(id) = 'blob';
                    CREATE TABLE sync_changes (
                        kind TEXT NOT NULL, id TEXT NOT NULL, modifiedAt REAL NOT NULL,
                        deleted INTEGER NOT NULL DEFAULT 0, contentHash TEXT,
                        PRIMARY KEY(kind, id)
                    );
                    CREATE TABLE sync_aliases (alias TEXT PRIMARY KEY NOT NULL, canonical TEXT NOT NULL);
                    """)
            let now = "((julianday('now') - 2440587.5) * 86400.0)"
            for (table, kind) in [("clips", "clip"), ("clip_lists", "list"), ("snippets", "snippet")] {
                let hash = table == "clips" ? "new.contentHash" : "NULL"
                let oldHash = table == "clips" ? "old.contentHash" : "NULL"
                for event in ["INSERT", "UPDATE"] {
                    try db.execute(
                        sql: """
                            CREATE TRIGGER sync_\(table)_\(event) AFTER \(event) ON \(table) BEGIN
                                INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted,contentHash)
                                VALUES ('\(kind)',new.id,MAX(\(now),COALESCE((SELECT modifiedAt + 0.000001 FROM sync_changes
                                    WHERE kind='\(kind)' AND id=new.id),0)),0,\(hash));
                            END;
                            """)
                }
                try db.execute(
                    sql: """
                        CREATE TRIGGER sync_\(table)_DELETE AFTER DELETE ON \(table) BEGIN
                            INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted,contentHash)
                            VALUES ('\(kind)',old.id,MAX(\(now),COALESCE((SELECT modifiedAt + 0.000001 FROM sync_changes
                                WHERE kind='\(kind)' AND id=old.id),0)),1,\(oldHash));
                        END;
                        """)
            }
        }

        migrator.registerMigration("v5_independent_usage_counters") { db in
            try db.execute(sql: """
                CREATE TABLE sync_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL);
                CREATE TABLE sync_usage (
                    clipId TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                    deviceId TEXT NOT NULL, count INTEGER NOT NULL CHECK(count >= 0),
                    PRIMARY KEY(clipId, deviceId)
                );
                INSERT INTO sync_usage SELECT id, 'legacy:' || id, pasteCount FROM clips WHERE pasteCount > 0;
                DROP TRIGGER sync_clips_UPDATE;
                CREATE TRIGGER sync_clips_UPDATE AFTER UPDATE ON clips
                WHEN new.contentHash IS NOT old.contentHash OR new.plainText IS NOT old.plainText
                  OR new.customName IS NOT old.customName OR new.primaryType IS NOT old.primaryType
                  OR new.sourceAppBundleId IS NOT old.sourceAppBundleId OR new.isFavorite IS NOT old.isFavorite
                  OR new.listId IS NOT old.listId OR new.manualSortIndex IS NOT old.manualSortIndex
                  OR new.createdAt IS NOT old.createdAt OR new.updatedAt IS NOT old.updatedAt
                BEGIN
                    INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted,contentHash)
                    VALUES ('clip',new.id,MAX((julianday('now') - 2440587.5) * 86400.0,
                        COALESCE((SELECT modifiedAt + 0.000001 FROM sync_changes
                            WHERE kind='clip' AND id=new.id),0)),0,new.contentHash);
                END;
                """)
            try db.execute(sql: "INSERT INTO sync_metadata VALUES ('deviceId', ?)", arguments: [UUID().uuidString.lowercased()])
            for event in ["INSERT", "UPDATE"] {
                try db.execute(sql: """
                    CREATE TRIGGER sync_usage_\(event) AFTER \(event) ON sync_usage BEGIN
                        INSERT INTO sync_changes(kind,id,modifiedAt,deleted)
                        VALUES ('usage',new.clipId,(julianday('now') - 2440587.5) * 86400.0,0)
                        ON CONFLICT(kind,id) DO UPDATE SET
                            modifiedAt=MAX(excluded.modifiedAt,sync_changes.modifiedAt+0.000001),deleted=0;
                    END;
                    """)
            }
        }

        migrator.registerMigration("v6_binary_content_identity") { db in
            try Self.migrateBinaryIdentities(in: db, blobStorage: blobStorage)
        }

        migrator.registerMigration("v7_independent_clip_metadata") { db in
            try Self.installMetadataClocks(in: db)
        }

        migrator.registerMigration("v8_restore_origins_and_blob_cleanup") { db in
            try Self.createBlobCleanupQueue(in: db)
            try db.execute(sql: """
                CREATE TABLE snippet_restore_origins (
                    originalId TEXT NOT NULL, payloadHash TEXT NOT NULL,
                    restoredId TEXT NOT NULL REFERENCES snippets(id) ON DELETE CASCADE,
                    PRIMARY KEY(originalId,payloadHash)
                );
                """)
            // Also collect representations orphaned by an already-applied version of migration v6.
            let files = (try? FileManager.default.contentsOfDirectory(atPath: blobStorage.baseDirectoryURL.path)) ?? []
            let hex = Set("0123456789abcdef")
            for filename in files where filename.count == 69 && filename.hasSuffix(".blob")
                && filename.prefix(64).allSatisfy({ hex.contains($0) }) {
                try db.execute(sql: "INSERT OR IGNORE INTO blob_gc_candidates VALUES (?)", arguments: [filename])
            }
        }

        return migrator
    }

    @discardableResult
    public func ingestCapturedClip(_ captured: CapturedClip) throws -> ClipRecord {
        try autoreleasepool {
            let contentHash = captured.computeContentHash()
            var representations = captured.representations
            if let text = captured.plainText { representations["public.utf8-plain-text"] = Data(text.utf8) }
            let candidates = representations.values.filter { $0.count > 4096 }.map { CapturedClip.hash($0) + ".blob" }
            var obsoleteBlobs: [String] = []
            do {
                let result = try dbWriter.write { db in
                    let activeAutoStarList = try ClipListRecord.filter(Column("isAutoStarActive") == true).fetchOne(db)

                    if var existing = try ClipRecord.filter(Column("contentHash") == contentHash).fetchOne(db) {
                        if !existing.isFavorite {
                            existing.updatedAt = Date()
                        }
                        // One capture supplies one coherent set of formats. Absent old formats are obsolete.
                        obsoleteBlobs = try self.replacePayloads(clipId: existing.id, representations: representations, db: db)
                        existing.primaryType = captured.primaryType
                        existing.plainText = captured.plainText
                        try existing.update(db)
                        try self.recordContentCapture(clipId: existing.id, contentHash: contentHash, db: db)
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

                    try self.replacePayloads(clipId: newClip.id, representations: representations, db: db)

                    return newClip
                }
                try removeUnreferencedBlobs(obsoleteBlobs)
                return result
            } catch {
                try? removeUnreferencedBlobs(candidates)
                throw error
            }
        }
    }

    public func searchClips(
        query: String = "",
        listId: UUID? = nil,
        sourceAppBundleId: String? = nil,
        primaryType: ClipPrimaryType? = nil,
        primaryTypes: [ClipPrimaryType]? = nil,
        favoritesOnly: Bool = false,
        sortMode: ClipSortMode = .updatedAtDesc,
        limit: Int = 100
    ) throws -> [ClipRecord] {
        try autoreleasepool {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectivePrimaryTypes: [ClipPrimaryType]? = {
                if let primaryTypes, !primaryTypes.isEmpty {
                    return primaryTypes
                } else if let primaryType {
                    return [primaryType]
                }
                return nil
            }()

            return try dbWriter.read { db in
                var effectiveSortMode = sortMode
                if let listId, sortMode == .updatedAtDesc {
                    if let list = try ClipListRecord.filter(Column("id") == listId.uuidString.lowercased()).fetchOne(db)
                    {
                        effectiveSortMode = list.sortMode
                    }
                }

                let orderClause: String
                switch effectiveSortMode {
                case .updatedAtDesc:
                    orderClause = "clips.updatedAt DESC, clips.createdAt DESC, clips.rowid DESC"
                case .createdAtDesc:
                    orderClause = "clips.createdAt DESC, clips.rowid DESC"
                case .pasteCountDesc:
                    orderClause = "clips.pasteCount DESC, clips.updatedAt DESC, clips.rowid DESC"
                case .manualOrder:
                    orderClause = "clips.manualSortIndex ASC, clips.updatedAt DESC, clips.rowid DESC"
                }

                if trimmed.isEmpty {
                    var request = ClipRecord.all()
                    if let listId {
                        request = request.filter(Column("listId") == listId.uuidString.lowercased())
                    }
                    if let sourceAppBundleId {
                        request = request.filter(Column("sourceAppBundleId") == sourceAppBundleId)
                    }
                    if let effectivePrimaryTypes {
                        request = request.filter(effectivePrimaryTypes.map(\.rawValue).contains(Column("primaryType")))
                    }
                    if favoritesOnly {
                        request = request.filter(Column("isFavorite") == true)
                    }

                    switch effectiveSortMode {
                    case .updatedAtDesc:
                        request = request.order(
                            Column("updatedAt").desc, Column("createdAt").desc, Column("rowid").desc)
                    case .createdAtDesc:
                        request = request.order(Column("createdAt").desc, Column("rowid").desc)
                    case .pasteCountDesc:
                        request = request.order(
                            Column("pasteCount").desc, Column("updatedAt").desc, Column("rowid").desc)
                    case .manualOrder:
                        request = request.order(
                            Column("manualSortIndex").asc, Column("updatedAt").desc, Column("rowid").desc)
                    }

                    return try request.limit(limit).fetchAll(db)
                }

                func fetchLiteralMatches() throws -> [ClipRecord] {
                    // Register on this reader too, including externally supplied writers. There is
                    // no pattern syntax: %, _ and backslashes remain literal after Unicode folding.
                    db.add(function: Self.literalContains)
                    let query = Self.literalSearchKey(trimmed)
                    var fallbackSql = """
                        SELECT * FROM clips
                        WHERE (concopy_literal_contains(plainText, ?) OR concopy_literal_contains(customName, ?))
                        """
                    var fallbackArgs: [DatabaseValueConvertible] = [query, query]

                    if let listId {
                        fallbackSql += " AND listId = ?"
                        fallbackArgs.append(listId.uuidString.lowercased())
                    }
                    if let sourceAppBundleId {
                        fallbackSql += " AND sourceAppBundleId = ?"
                        fallbackArgs.append(sourceAppBundleId)
                    }
                    if let effectivePrimaryTypes {
                        let placeholders = Array(repeating: "?", count: effectivePrimaryTypes.count).joined(separator: ", ")
                        fallbackSql += " AND primaryType IN (\(placeholders))"
                        fallbackArgs.append(contentsOf: effectivePrimaryTypes.map(\.rawValue))
                    }
                    if favoritesOnly {
                        fallbackSql += " AND isFavorite = 1"
                    }
                    fallbackSql += " ORDER BY \(orderClause) LIMIT ?"
                    fallbackArgs.append(limit)

                    return try ClipRecord.fetchAll(db, sql: fallbackSql, arguments: StatementArguments(fallbackArgs))
                }

                // Keep punctuation and symbols significant, including in mixed text such as ~/Library or c++.
                // Combining marks belong to words and must not switch ordinary accented text to literal search.
                let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
                let containsSymbols = trimmed.unicodeScalars.contains {
                    !wordCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
                }
                if containsSymbols {
                    return try fetchLiteralMatches()
                }

                let words = trimmed.unicodeScalars.split { !wordCharacters.contains($0) }
                    .map { String($0) }
                    .filter { !$0.isEmpty }
                guard !words.isEmpty else {
                    return try fetchLiteralMatches()
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
                if let effectivePrimaryTypes {
                    let placeholders = Array(repeating: "?", count: effectivePrimaryTypes.count).joined(separator: ", ")
                    sql += " AND clips.primaryType IN (\(placeholders))"
                    arguments.append(contentsOf: effectivePrimaryTypes.map(\.rawValue))
                }
                if favoritesOnly {
                    sql += " AND clips.isFavorite = 1"
                }
                sql += " ORDER BY \(orderClause) LIMIT ?"
                arguments.append(limit)

                do {
                    return try ClipRecord.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
                } catch {
                    return try fetchLiteralMatches()
                }
            }
        }
    }

    public func updateTextContent(clipId: UUID, newPlainText: String) throws {
        let idString = clipId.uuidString.lowercased()
        let newHash = CapturedClip(plainText: newPlainText).computeContentHash()
        var oldBlobs: [String] = []
        do {
            try dbWriter.write { db in
                guard var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) else {
                    throw DatabaseError(message: "Clip not found")
                }
                clip.plainText = newPlainText
                clip.contentHash = newHash
                clip.primaryType = .text
                clip.updatedAt = Date()
                try clip.update(db)
                // Old rich formats contain the old text and must not survive an edit.
                oldBlobs = try replacePayloads(
                    clipId: clipId,
                    representations: ["public.utf8-plain-text": Data(newPlainText.utf8)], db: db)
            }
            try removeUnreferencedBlobs(oldBlobs)
        } catch {
            if newPlainText.utf8.count > 4096 {
                try? removeUnreferencedBlobs([CapturedClip.hash(Data(newPlainText.utf8)) + ".blob"])
            }
            throw error
        }
    }

    /// Called only while holding the database writer; filesystem cleanup happens after commit.
    @discardableResult
    internal func replacePayloads(clipId: UUID, representations: [String: Data], db: Database) throws -> [String] {
        let id = clipId.uuidString.lowercased()
        let previous = try ClipPayloadRecord.filter(Column("clipId") == id).fetchAll(db)
        try ClipPayloadRecord.filter(Column("clipId") == id).deleteAll(db)
        for (uti, data) in representations {
            let payload: ClipPayloadRecord
            if data.count > 4096 {
                payload = ClipPayloadRecord(
                    clipId: clipId, utiType: uti,
                    blobFilename: try blobStorage.storeBlob(data: data), byteSize: data.count)
            } else {
                payload = ClipPayloadRecord(clipId: clipId, utiType: uti, inlineData: data, byteSize: data.count)
            }
            try payload.insert(db)
        }
        return previous.compactMap(\.blobFilename)
    }

    internal func removeUnreferencedBlobs(_ filenames: [String]) throws {
        // Serialize the reference check AND deletion against all payload writes.
        try dbWriter.write { db in
            for filename in Set(filenames) {
                if try ClipPayloadRecord.filter(Column("blobFilename") == filename).fetchCount(db) == 0 {
                    try blobStorage.deleteBlobIfExists(filename: filename)
                }
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
        let result = try dbWriter.write { db in
            try deleteClips([clipId], in: db)
        }
        try removeUnreferencedBlobs(result.blobs)
    }

    /// The caller owns one write transaction for candidate selection and all deletions.
    private func deleteClips(_ ids: [UUID], in db: Database, preserveSaved: Bool = false) throws
        -> (count: Int, blobs: [String])
    {
        var deleted = 0
        var blobs: [String] = []
        for id in ids {
            let key = id.uuidString.lowercased()
            var request = ClipRecord.filter(Column("id") == key)
            if preserveSaved {
                request = request.filter(Column("isFavorite") == false && Column("listId") == nil)
            }
            guard try request.fetchCount(db) > 0 else { continue }
            let candidates = try ClipPayloadRecord.filter(Column("clipId") == key).fetchAll(db)
                .compactMap(\.blobFilename)
            let count = try request.deleteAll(db)
            deleted += count
            if count > 0 { blobs += candidates }
        }
        return (deleted, blobs)
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
        let blobs = try dbWriter.write { db -> [String] in
            var blobs: [String] = []
            if deleteContainedClips {
                let clips = try ClipRecord.filter(Column("listId") == idString).fetchAll(db)
                blobs = try deleteClips(clips.map(\.id), in: db).blobs
            } else {
                try db.execute(sql: "UPDATE clips SET listId = NULL WHERE listId = ?", arguments: [idString])
            }
            try ClipListRecord.filter(Column("id") == idString).deleteAll(db)
            return blobs
        }
        try removeUnreferencedBlobs(blobs)
    }

    @discardableResult
    public func clearAllHistory(preserveFavorites: Bool = true) throws -> Int {
        let result = try dbWriter.write { db in
            var request = ClipRecord.all()
            if preserveFavorites {
                request = request.filter(Column("isFavorite") == false && Column("listId") == nil)
            }
            let clips = try request.fetchAll(db)
            return try deleteClips(clips.map(\.id), in: db, preserveSaved: preserveFavorites)
        }
        try removeUnreferencedBlobs(result.blobs)
        return result.count
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
                throw DatabaseError(message: "Clip not found")
            }
            clip.isFavorite.toggle()
            try clip.update(db)
            return clip
        }
    }

    @discardableResult
    public func assignClip(clipId: UUID, toListId listId: UUID?, markFavorite: Bool = false) throws -> ClipRecord {
        let idString = clipId.uuidString.lowercased()
        return try dbWriter.write { db in
            guard var clip = try ClipRecord.filter(Column("id") == idString).fetchOne(db) else {
                throw DatabaseError(message: "Clip not found")
            }
            clip.listId = listId
            if markFavorite && listId != nil {
                clip.isFavorite = true
            }
            if !clip.isFavorite {
                clip.updatedAt = Date()
            }
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
                guard clip.pasteCount >= 0, clip.pasteCount < Int.max else {
                    throw DatabaseError(message: "Invalid usage counter")
                }
                let known = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(count),0) FROM sync_usage WHERE clipId=?",
                    arguments: [idString]) ?? 0
                if clip.pasteCount > known {
                    try db.execute(sql: """
                        INSERT INTO sync_usage(clipId,deviceId,count) VALUES (?,?,?)
                        ON CONFLICT(clipId,deviceId) DO UPDATE SET count=count+excluded.count
                        """, arguments: [idString, "legacy:" + idString, clip.pasteCount - known])
                }
                let device = (try String.fetchOne(db, sql: "SELECT value FROM sync_metadata WHERE key='deviceId'")
                    ?? "local") + ":" + idString
                try db.execute(sql: """
                    INSERT INTO sync_usage(clipId,deviceId,count) VALUES (?,?,1)
                    ON CONFLICT(clipId,deviceId) DO UPDATE SET count=count+1
                    """, arguments: [idString, device])
                clip.pasteCount += 1
                try clip.update(db)
                return clip
            }
            return nil
        }
    }

    @discardableResult
    public func pruneClips(olderThanDays days: Int? = nil, maxCount: Int? = nil) throws -> Int {
        let result = try dbWriter.write { db in
            var clipsToDelete: [UUID] = []
            var remainingNonFavorites: [ClipRecord] = []

            let cutoffDate = days.flatMap { $0 > 0 ? Date().addingTimeInterval(-Double($0) * 86400) : nil }

            let allNonFavorites =
                try ClipRecord
                .filter(Column("isFavorite") == false && Column("listId") == nil)
                .order(Column("updatedAt").desc, Column("createdAt").desc, Column("rowid").desc)
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
            return try deleteClips(clipsToDelete, in: db, preserveSaved: true)
        }
        try removeUnreferencedBlobs(result.blobs)
        return result.count
    }

    // MARK: - Snippets Management
    public func saveSnippet(_ snippet: SnippetRecord) throws {
        try dbWriter.write { db in
            try snippet.save(db)
        }
    }

    public func fetchSnippets() throws -> [SnippetRecord] {
        try dbWriter.read { db in
            try SnippetRecord.order(Column("createdAt").desc).fetchAll(db)
        }
    }

    public func fetchSnippet(byShortcut shortcut: String) throws -> SnippetRecord? {
        try dbWriter.read { db in
            try SnippetRecord.filter(Column("shortcut") == shortcut).fetchOne(db)
        }
    }

    public func deleteSnippet(id: UUID) throws {
        try dbWriter.write { db in
            _ = try SnippetRecord.filter(Column("id") == id.uuidString.lowercased()).deleteAll(db)
        }
    }
}

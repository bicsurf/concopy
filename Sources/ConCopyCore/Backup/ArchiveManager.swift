import Foundation
import GRDB

public struct BackupPayloadItem: Codable, Sendable {
    public let utiType: String
    public let base64Data: String
    public let byteSize: Int
    public let sha256: String?

    public init(utiType: String, base64Data: String, byteSize: Int, sha256: String? = nil) {
        self.utiType = utiType
        self.base64Data = base64Data
        self.byteSize = byteSize
        self.sha256 = sha256
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
    public let snippets: [SnippetRecord]
    public let usage: [String: [String: Int]]
    public let snippetOrigins: [SnippetRestoreOrigin]

    public init(
        version: Int = 2,
        appVersion: String = "1.0.0",
        exportedAt: Date = Date(),
        lists: [ClipListRecord],
        clips: [BackupClipItem],
        snippets: [SnippetRecord] = [], usage: [String: [String: Int]] = [:],
        snippetOrigins: [SnippetRestoreOrigin] = []
    ) {
        self.version = version
        self.appVersion = appVersion
        self.exportedAt = exportedAt
        self.lists = lists
        self.clips = clips
        self.snippets = snippets
        self.usage = usage
        self.snippetOrigins = snippetOrigins
    }
    private enum CodingKeys: String, CodingKey { case version, appVersion, exportedAt, lists, clips, snippets, usage, snippetOrigins }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        appVersion = try c.decode(String.self, forKey: .appVersion)
        exportedAt = try c.decode(Date.self, forKey: .exportedAt)
        lists = try c.decode([ClipListRecord].self, forKey: .lists)
        clips = try c.decode([BackupClipItem].self, forKey: .clips)
        snippets = try c.decodeIfPresent([SnippetRecord].self, forKey: .snippets) ?? []
        usage = try c.decodeIfPresent([String: [String: Int]].self, forKey: .usage) ?? [:]
        snippetOrigins = try c.decodeIfPresent([SnippetRestoreOrigin].self, forKey: .snippetOrigins) ?? []
    }

}

public enum ArchiveError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidPayload(String)
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Unsupported archive version: \(version)"
        case .invalidPayload(let uti): return "Invalid or damaged payload: \(uti)"
        }
    }
}

public struct ArchiveManager: Sendable {
    public init() {}

    public func exportArchive(to destinationURL: URL, databaseManager: DatabaseManager) async throws {
        let archive = try databaseManager.makeArchive()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: destinationURL, options: .atomic)
    }

    public func importArchive(from sourceURL: URL, databaseManager: DatabaseManager) async throws {
        let archive = try autoreleasepool {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ConCopyArchive.self, from: Data(contentsOf: sourceURL, options: .mappedIfSafe))
        }
        guard (1...2).contains(archive.version) else { throw ArchiveError.unsupportedVersion(archive.version) }
        var storedBlobs: [String] = []
        for item in archive.clips {
            try autoreleasepool {
                let representations = try Self.validatedRepresentations(item.payloads)
                storedBlobs += representations.values.filter { $0.count > 4096 }.map { CapturedClip.hash($0) + ".blob" }
            }
        }
        do {
            let obsoleteBlobs = try await databaseManager.dbWriter.write { db -> [String] in
                var obsoleteBlobs: [String] = []
                for list in archive.lists { try list.save(db) }
                for item in archive.clips {
                    try autoreleasepool {
                        let representations = try Self.validatedRepresentations(item.payloads)
                        let hash = CapturedClip(plainText: item.plainText, primaryType: item.primaryType,
                            representations: representations).migratedContentHash(fallback: item.contentHash)
                        var match = try ClipRecord.filter(Column("contentHash") == hash).fetchOne(db)
                        if match == nil {
                            // A pre-upgrade damaged blob may have prevented identity migration.
                            match = try ClipRecord.filter(Column("id") == item.id.uuidString.lowercased()
                                && Column("contentHash") == item.contentHash
                                && Column("primaryType") == item.primaryType.rawValue).fetchOne(db)
                        }
                        if var found = match {
                            found.contentHash = hash
                            found.updatedAt = max(found.updatedAt, item.updatedAt)
                            found.isFavorite = found.isFavorite || item.isFavorite
                            found.listId = found.listId ?? item.listId
                            found.customName = found.customName ?? item.customName
                            try found.update(db)
                            // Repair incomplete historic imports without replacing local representations.
                            let payloads = try ClipPayloadRecord.filter(
                                Column("clipId") == found.id.uuidString.lowercased()
                            ).fetchAll(db)
                            var merged = representations
                            for payload in payloads {
                                if let bytes = try? databaseManager.loadPayloadData(for: payload), bytes.count == payload.byteSize {
                                    merged[payload.utiType] = bytes
                                } else if merged[payload.utiType] == nil {
                                    throw ArchiveError.invalidPayload(payload.utiType)
                                }
                            }
                            obsoleteBlobs += try databaseManager.replacePayloads(clipId: found.id, representations: merged, db: db)
                            try Self.restoreUsage(archive.usage[item.id.uuidString.lowercased()],
                                legacyCount: item.pasteCount, originalId: item.id, clipId: found.id, db: db)
                        } else {
                            // A backup is additive: retain the edited local version and restore the old content with a new ID.
                            let idExists =
                                try ClipRecord.filter(Column("id") == item.id.uuidString.lowercased()).fetchCount(db)
                                > 0
                            var clip = item.record(id: idExists ? UUID() : item.id)
                            clip.contentHash = hash
                            try clip.insert(db)
                            try databaseManager.replacePayloads(
                                clipId: clip.id, representations: representations, db: db)
                            try Self.restoreUsage(archive.usage[item.id.uuidString.lowercased()],
                                legacyCount: item.pasteCount, originalId: item.id, clipId: clip.id, db: db)
                        }
                    }
                }
                var snippetIDs: [UUID: UUID] = [:]
                for snippet in archive.snippets {
                    snippetIDs[snippet.id] = try Self.restoreSnippet(snippet, in: db)
                }
                for var origin in archive.snippetOrigins {
                    guard let restored = snippetIDs[origin.restoredId] else { throw ArchiveError.invalidPayload("snippet origin") }
                    origin.restoredId = restored
                    try origin.save(db)
                }
                return obsoleteBlobs
            }
            try databaseManager.removeUnreferencedBlobs(obsoleteBlobs)
        } catch {
            try? databaseManager.removeUnreferencedBlobs(storedBlobs)
            throw error
        }
    }

    private static func restoreUsage(_ saved: [String: Int]?, legacyCount: Int, originalId: UUID, clipId: UUID, db: Database) throws {
        let key = clipId.uuidString.lowercased()
        let components = saved ?? (legacyCount > 0 ? ["legacy:" + originalId.uuidString.lowercased(): legacyCount] : [:])
        for (device, count) in components {
            guard count >= 0 else { throw ArchiveError.invalidPayload("usage counter") }
            try db.execute(sql: """
                INSERT INTO sync_usage(clipId,deviceId,count) VALUES (?,?,?)
                ON CONFLICT(clipId,deviceId) DO UPDATE SET count=MAX(count,excluded.count)
                """, arguments: [key,device,count])
        }
        let count = try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(count),0) FROM sync_usage WHERE clipId=?",
            arguments: [key]) ?? 0
        try db.execute(sql: "UPDATE clips SET pasteCount=MAX(pasteCount,?) WHERE id=?", arguments: [count,key])
    }

    private struct SnippetVersion: Encodable {
        var shortcut: String
        var content: String
        var title: String?
    }

    private static func restoreSnippet(_ snippet: SnippetRecord, in db: Database) throws -> UUID {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let hash = CapturedClip.hash(try encoder.encode(SnippetVersion(shortcut: snippet.shortcut, content: snippet.content, title: snippet.title)))
        if let origin = try SnippetRestoreOrigin.filter(Column("originalId") == snippet.id.uuidString.lowercased()
            && Column("payloadHash") == hash).fetchOne(db),
            let restored = try SnippetRecord.filter(Column("id") == origin.restoredId.uuidString.lowercased()).fetchOne(db),
            restored.content == snippet.content, restored.title == snippet.title { return restored.id }
        if let existing = try SnippetRecord.filter(Column("id") == snippet.id.uuidString.lowercased()).fetchOne(db),
            existing.shortcut == snippet.shortcut, existing.content == snippet.content, existing.title == snippet.title {
            try SnippetRestoreOrigin(originalId: snippet.id, payloadHash: hash, restoredId: existing.id).save(db)
            return existing.id
        }
        let restoredPrefix = snippet.shortcut + "~restored"
        var copy = snippet
        if try SnippetRecord.filter(Column("id") == snippet.id.uuidString.lowercased()).fetchCount(db) > 0 {
            var attempt = 0
            while true {
                let digest = CapturedClip.hash(Data((snippet.id.uuidString.lowercased() + ":" + hash + ":\(attempt)").utf8))
                let hex = Array(digest.prefix(32))
                let value = String(hex[0..<8]) + "-" + String(hex[8..<12]) + "-" + String(hex[12..<16])
                    + "-" + String(hex[16..<20]) + "-" + String(hex[20..<32])
                guard let candidate = UUID(uuidString: value) else { throw ArchiveError.invalidPayload("snippet identity") }
                if let existing = try SnippetRecord.filter(Column("id") == candidate.uuidString.lowercased()).fetchOne(db) {
                    if existing.content == snippet.content, existing.title == snippet.title {
                        try SnippetRestoreOrigin(originalId: snippet.id, payloadHash: hash, restoredId: candidate).save(db)
                        return candidate
                    }
                } else { copy.id = candidate; break }
                attempt += 1
            }
        }
        var suffix = 1
        while try SnippetRecord.filter(Column("shortcut") == copy.shortcut).fetchCount(db) > 0 {
            copy.shortcut = restoredPrefix + (suffix == 1 ? "" : "-\(suffix)")
            suffix += 1
        }
        try copy.insert(db)
        try SnippetRestoreOrigin(originalId: snippet.id, payloadHash: hash, restoredId: copy.id).save(db)
        return copy.id
    }

    internal static func validatedRepresentations(_ payloads: [BackupPayloadItem]) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for payload in payloads {
            guard let data = Data(base64Encoded: payload.base64Data), data.count == payload.byteSize,
                payload.sha256.map({ CapturedClip.hash(data) == $0 }) ?? true,
                result[payload.utiType] == nil
            else { throw ArchiveError.invalidPayload(payload.utiType) }
            result[payload.utiType] = data
        }
        return result
    }
}

extension BackupClipItem {
    internal func record(id: UUID? = nil) -> ClipRecord {
        ClipRecord(
            id: id ?? self.id, contentHash: contentHash, plainText: plainText, customName: customName,
            primaryType: primaryType, sourceAppBundleId: sourceAppBundleId, isFavorite: isFavorite,
            listId: listId, pasteCount: pasteCount, manualSortIndex: manualSortIndex,
            createdAt: createdAt, updatedAt: updatedAt)
    }
}

extension DatabaseManager {
    /// The writer also protects physical blob lifetime; a SQL reader snapshot alone cannot do that.
    internal func makeArchive(in database: Database? = nil, willReadPayloads: (() -> Void)? = nil) throws -> ConCopyArchive {
        func snapshot(_ db: Database) throws -> ConCopyArchive {
            let lists = try ClipListRecord.fetchAll(db)
            let snippets = try SnippetRecord.fetchAll(db)
            let cursor = try ClipRecord.fetchCursor(db)
            var clips: [BackupClipItem] = []
            while let clip = try cursor.next() {
                if clips.isEmpty { willReadPayloads?() }
                let item = try autoreleasepool { () -> BackupClipItem in
                    let payloads = try ClipPayloadRecord.filter(Column("clipId") == clip.id.uuidString.lowercased())
                        .fetchAll(db)
                    let backupPayloads = try payloads.map { payload -> BackupPayloadItem in
                        let data = try loadPayloadData(for: payload)
                        return BackupPayloadItem(
                            utiType: payload.utiType, base64Data: data.base64EncodedString(),
                            byteSize: data.count, sha256: CapturedClip.hash(data))
                    }
                    return BackupClipItem(
                        id: clip.id, contentHash: clip.contentHash, plainText: clip.plainText,
                        customName: clip.customName, primaryType: clip.primaryType,
                        sourceAppBundleId: clip.sourceAppBundleId,
                        isFavorite: clip.isFavorite, listId: clip.listId, pasteCount: clip.pasteCount,
                        manualSortIndex: clip.manualSortIndex, createdAt: clip.createdAt, updatedAt: clip.updatedAt,
                        payloads: backupPayloads)
                }
                clips.append(item)
            }
            var usage: [String: [String: Int]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT clipId,deviceId,count FROM sync_usage") {
                let key: String = row["clipId"], device: String = row["deviceId"], count: Int = row["count"]
                usage[key, default: [:]][device] = count
            }
            return ConCopyArchive(lists: lists, clips: clips, snippets: snippets, usage: usage,
                snippetOrigins: try SnippetRestoreOrigin.fetchAll(db))
        }
        if let database { return try snapshot(database) }
        return try dbWriter.write(snapshot)
    }
}

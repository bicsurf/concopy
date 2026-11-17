import Foundation
import GRDB

private struct MigrationJournalEntry {
    var kind: String
    var id: String
    var modifiedAt: Double
    var deleted: Bool
    var contentHash: String?
}

extension DatabaseManager {
    /// Rebuild binary identities from their payloads, retaining IDs, metadata and offline aliases.
    internal static func migrateBinaryIdentities(in db: Database, blobStorage: BlobStorageManager) throws {
        try Self.createBlobCleanupQueue(in: db)
        var journal: [String: MigrationJournalEntry] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM sync_changes") {
            let entry = MigrationJournalEntry(kind: row["kind"], id: row["id"], modifiedAt: row["modifiedAt"],
                deleted: row["deleted"], contentHash: row["contentHash"])
            journal[entry.kind + ":" + entry.id] = entry
        }
        var groups: [String: [ClipRecord]] = [:]
        let records = try ClipRecord.filter(["file", "image"].contains(Column("primaryType"))).fetchAll(db)
        for clip in records {
            let hash = try autoreleasepool { () throws -> String in
                let payloads = try ClipPayloadRecord.filter(Column("clipId") == clip.id.uuidString.lowercased()).fetchAll(db)
                var representations: [String: Data] = [:]
                for payload in payloads {
                    if let inline = payload.inlineData { representations[payload.utiType] = inline }
                    else if let file = payload.blobFilename, let data = try? blobStorage.loadBlob(filename: file) {
                        representations[payload.utiType] = data
                    }
                }
                return CapturedClip(plainText: clip.plainText, primaryType: clip.primaryType,
                    representations: representations).migratedContentHash(fallback: clip.contentHash)
            }
            groups[hash, default: []].append(clip)
        }
        for (hash, group) in groups {
            guard group.count > 1 || group.first?.contentHash != hash else { continue }
            let newest = group.sorted {
                $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
            }
            guard var winner = newest.first,
                let canonical = group.min(by: { $0.id.uuidString < $1.id.uuidString }) else { continue }
            let key = canonical.id.uuidString.lowercased()
            // Rehashing is not a user edit. Preserve the pre-migration content clock, including deletions.
            let contentClock = group.map { clip -> Double in
                let entry = journal["clip:" + clip.id.uuidString.lowercased()]
                return entry?.deleted == false ? (entry?.modifiedAt ?? clip.updatedAt.timeIntervalSince1970)
                    : clip.updatedAt.timeIntervalSince1970
            }.max() ?? winner.updatedAt.timeIntervalSince1970
            let previous = journal["clip:" + key]
            let keepDeletion = previous?.deleted == true && (previous?.modifiedAt ?? 0) >= contentClock
            journal["clip:" + key] = MigrationJournalEntry(kind: "clip", id: key,
                modifiedAt: keepDeletion ? (previous?.modifiedAt ?? contentClock) : contentClock,
                deleted: keepDeletion, contentHash: hash)
            let payloads = try ClipPayloadRecord.filter(Column("clipId") == winner.id.uuidString.lowercased()).fetchAll(db)
            var usage: [String: Int] = [:]
            for clip in group {
                for payload in try ClipPayloadRecord.filter(Column("clipId") == clip.id.uuidString.lowercased()).fetchAll(db) {
                    if let filename = payload.blobFilename {
                        try db.execute(sql: "INSERT OR IGNORE INTO blob_gc_candidates VALUES (?)", arguments: [filename])
                    }
                }
                for row in try Row.fetchAll(db, sql: "SELECT deviceId,count FROM sync_usage WHERE clipId=?",
                    arguments: [clip.id.uuidString.lowercased()]) {
                    let device: String = row["deviceId"], count: Int = row["count"]
                    usage[device] = max(usage[device] ?? 0, count)
                }
                // Free unique hashes before assigning the migrated canonical value.
                try db.execute(sql: "UPDATE clips SET contentHash=? WHERE id=?",
                    arguments: ["identity-migration:" + clip.id.uuidString.lowercased(), clip.id.uuidString.lowercased()])
            }
            winner.id = canonical.id
            winner.contentHash = hash
            winner.isFavorite = group.contains(where: \.isFavorite)
            winner.customName = newest.compactMap(\.customName).first
            winner.listId = newest.compactMap(\.listId).first
            winner.manualSortIndex = newest.first(where: { $0.listId == winner.listId })?.manualSortIndex ?? 0
            winner.createdAt = group.map(\.createdAt).min() ?? winner.createdAt
            winner.pasteCount = try usage.values.reduce(0) { total, value in
                let sum = total.addingReportingOverflow(value)
                guard value >= 0, !sum.overflow else { throw DatabaseError(message: "Invalid usage counter") }
                return sum.partialValue
            }
            try winner.update(db)
            try ClipPayloadRecord.filter(Column("clipId") == key).deleteAll(db)
            for var payload in payloads {
                payload.id = UUID()
                payload.clipId = canonical.id
                try payload.insert(db)
            }
            for clip in group where clip.id != canonical.id {
                let alias = clip.id.uuidString.lowercased()
                // GRDB may disable foreign keys while migrating; do not rely on ON DELETE CASCADE here.
                try ClipPayloadRecord.filter(Column("clipId") == alias).deleteAll(db)
                try db.execute(sql: "DELETE FROM sync_usage WHERE clipId=?", arguments: [alias])
                try ClipRecord.filter(Column("id") == alias).deleteAll(db)
                // Deduplication is an identity change, not a user deletion.
                try db.execute(sql: "DELETE FROM sync_changes WHERE id=?", arguments: [alias])
                try db.execute(sql: "UPDATE sync_aliases SET canonical=? WHERE canonical=?", arguments: [key,alias])
                try db.execute(sql: "INSERT OR REPLACE INTO sync_aliases(alias,canonical) VALUES (?,?)", arguments: [alias,key])
            }
            try db.execute(sql: "DELETE FROM sync_aliases WHERE alias=?", arguments: [key])
            try db.execute(sql: "DELETE FROM sync_usage WHERE clipId=?", arguments: [key])
            for (device, count) in usage {
                try db.execute(sql: "INSERT INTO sync_usage(clipId,deviceId,count) VALUES (?,?,?)", arguments: [key,device,count])
            }
        }
        // SQL triggers ran while rebuilding rows; none of those technical updates may advance a clock.
        try db.execute(sql: "DELETE FROM sync_changes")
        for entry in journal.values {
            try db.execute(sql: "INSERT INTO sync_changes(kind,id,modifiedAt,deleted,contentHash) VALUES (?,?,?,?,?)",
                arguments: [entry.kind, entry.id, entry.modifiedAt, entry.deleted, entry.contentHash])
        }
    }

    internal static func createBlobCleanupQueue(in db: Database) throws {
        try db.execute(sql: "CREATE TABLE IF NOT EXISTS blob_gc_candidates(filename TEXT PRIMARY KEY NOT NULL)")
    }

    internal func collectMigrationBlobs() throws {
        try dbWriter.write { db in
            for filename in try String.fetchAll(db, sql: "SELECT filename FROM blob_gc_candidates") {
                if try ClipPayloadRecord.filter(Column("blobFilename") == filename).fetchCount(db) == 0 {
                    try blobStorage.deleteBlobIfExists(filename: filename)
                }
                try db.execute(sql: "DELETE FROM blob_gc_candidates WHERE filename=?", arguments: [filename])
            }
        }
    }
}

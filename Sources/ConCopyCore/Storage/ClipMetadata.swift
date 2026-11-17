import Foundation
import GRDB

internal enum ClipMetadataField: String, CaseIterable, Sendable {
    case isFavorite, customName, listId, manualSortIndex

    func value(in clip: ClipRecord) -> ClipMetadataValue {
        switch self {
        case .isFavorite: return .flag(clip.isFavorite)
        case .customName: return .text(clip.customName)
        case .listId: return .list(clip.listId)
        case .manualSortIndex: return .order(clip.manualSortIndex)
        }
    }
}

internal enum ClipMetadataValue: Sendable {
    case flag(Bool), text(String?), list(UUID?), order(Int)

    var isDefault: Bool {
        switch self {
        case .flag(let value): return !value
        case .text(let value): return value == nil || value?.isEmpty == true
        case .list(let value): return value == nil
        case .order(let value): return value == 0
        }
    }

    private var stableKey: String {
        switch self {
        case .flag(let value): return value ? "1" : "0"
        case .text(let value): return value.map { "1:" + $0 } ?? "0"
        case .list(let value): return value.map { "1:" + $0.uuidString.lowercased() } ?? "0"
        case .order(let value): return String(value)
        }
    }

    func precedes(_ other: ClipMetadataValue) -> Bool {
        stableKey.utf8.lexicographicallyPrecedes(other.stableKey.utf8)
    }

    func apply(to clip: inout ClipRecord) {
        switch self {
        case .flag(let value): clip.isFavorite = value
        case .text(let value): clip.customName = value
        case .list(let value): clip.listId = value
        case .order(let value): clip.manualSortIndex = value
        }
    }
}

internal struct VersionedClipMetadata: Sendable {
    var value: ClipMetadataValue
    var modifiedAt: Date

    func wins(over other: VersionedClipMetadata) -> Bool {
        modifiedAt == other.modifiedAt ? value.precedes(other.value) : modifiedAt > other.modifiedAt
    }
}

extension DatabaseManager {
    internal static func installMetadataClocks(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE sync_clip_metadata (
                clipId TEXT NOT NULL REFERENCES clips(id) ON DELETE CASCADE,
                field TEXT NOT NULL, modifiedAt REAL NOT NULL, PRIMARY KEY(clipId,field)
            );
            DROP TRIGGER sync_clips_UPDATE;
            CREATE TRIGGER sync_clips_UPDATE AFTER UPDATE ON clips
            WHEN new.contentHash IS NOT old.contentHash OR new.plainText IS NOT old.plainText
              OR new.primaryType IS NOT old.primaryType OR new.sourceAppBundleId IS NOT old.sourceAppBundleId
            BEGIN
                INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted,contentHash)
                VALUES ('clip',new.id,MAX((julianday('now') - 2440587.5) * 86400.0,
                    COALESCE((SELECT modifiedAt+0.000001 FROM sync_changes WHERE kind='clip' AND id=new.id),0)),0,new.contentHash);
            END;
            """)
        // Old formats did not distinguish implicit defaults from explicit clears. Seed only retained user values.
        let cursor = try ClipRecord.fetchCursor(db)
        while let clip = try cursor.next() {
            try autoreleasepool {
                let date = try Double.fetchOne(db, sql: "SELECT modifiedAt FROM sync_changes WHERE kind='clip' AND id=? AND deleted=0",
                    arguments: [clip.id.uuidString.lowercased()]) ?? clip.updatedAt.timeIntervalSince1970
                for field in ClipMetadataField.allCases where !field.value(in: clip).isDefault {
                    try db.execute(sql: "INSERT INTO sync_clip_metadata VALUES (?,?,?)",
                        arguments: [clip.id.uuidString.lowercased(), field.rawValue, date])
                }
            }
        }
        let now = "((julianday('now') - 2440587.5) * 86400.0)"
        for field in ClipMetadataField.allCases {
            let column = field.rawValue
            let nondefault = field == .isFavorite || field == .manualSortIndex ? "new.\(column) != 0" : "new.\(column) IS NOT NULL"
            for event in ["INSERT", "UPDATE"] {
                let condition = event == "INSERT" ? nondefault : "new.\(column) IS NOT old.\(column)"
                try db.execute(sql: """
                    CREATE TRIGGER metadata_\(column)_\(event) AFTER \(event) ON clips WHEN \(condition) BEGIN
                        INSERT INTO sync_clip_metadata(clipId,field,modifiedAt)
                        VALUES (new.id,'\(column)',\(now))
                        ON CONFLICT(clipId,field) DO UPDATE SET modifiedAt=MAX(excluded.modifiedAt,modifiedAt+0.000001);
                    END;
                    """)
            }
        }
        for event in ["INSERT", "UPDATE"] {
            try db.execute(sql: """
                CREATE TRIGGER metadata_journal_\(event) AFTER \(event) ON sync_clip_metadata BEGIN
                    INSERT INTO sync_changes(kind,id,modifiedAt,deleted) VALUES ('metadata',new.clipId,new.modifiedAt,0)
                    ON CONFLICT(kind,id) DO UPDATE SET modifiedAt=MAX(excluded.modifiedAt,modifiedAt+0.000001),deleted=0;
                END;
                """)
        }
    }

    internal func recordContentCapture(clipId: UUID, contentHash: String, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sync_changes(kind,id,modifiedAt,deleted,contentHash)
            VALUES ('clip',?,(julianday('now') - 2440587.5) * 86400.0,0,?)
            ON CONFLICT(kind,id) DO UPDATE SET modifiedAt=MAX(excluded.modifiedAt,modifiedAt+0.000001),
                deleted=0,contentHash=excluded.contentHash
            """, arguments: [clipId.uuidString.lowercased(), contentHash])
    }
}

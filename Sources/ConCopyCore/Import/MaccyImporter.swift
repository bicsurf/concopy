import Foundation
import GRDB

public struct MaccyImporter: ExternalClipboardImporter {
    public let displayName: String = "Maccy"
    public let sourceURL: URL

    public static let standardLocations: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Maccy", isDirectory: true)
    ]

    public static func detectStandardDatabaseURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = ["Storage.sqlite", "History.sqlite"]

        for dir in standardLocations {
            for name in candidates {
                let fileURL = dir.appendingPathComponent(name)
                if fileManager.fileExists(atPath: fileURL.path) {
                    return fileURL
                }
            }
        }
        return nil
    }

    public init(sourceURL: URL) {
        self.sourceURL = sourceURL
    }

    public func importClips(
        into databaseManager: DatabaseManager,
        progress: ImportProgressHandler?
    ) throws -> ImportResult {
        let targetFileURL = try resolveDatabaseFile(from: sourceURL)
        let sourceDB = try SourceDatabase(sourceFileURL: targetFileURL)

        return try sourceDB.queue.read { db in
            try validateTablesExist(in: db)

            let historyItemColumns = try fetchTableColumnNames(table: "ZHISTORYITEM", db: db)
            let contentColumns = try fetchTableColumnNames(table: "ZHISTORYITEMCONTENT", db: db)

            let fkColumnName = try detectForeignKeyColumn(in: contentColumns, db: db)

            let totalItems = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZHISTORYITEM") ?? 0

            let contentMap = try fetchContentMap(fkColumn: fkColumnName, in: db)

            let batchImporter = ClipBatchImporter()

            return try batchImporter.run(
                into: databaseManager,
                totalCount: totalItems,
                enumerate: { yield in
                    let itemRows = try Row.fetchAll(db, sql: "SELECT * FROM ZHISTORYITEM ORDER BY Z_PK ASC")

                    for row in itemRows {
                        do {
                            if let clipItem = try parseHistoryItem(
                                row: row,
                                columns: historyItemColumns,
                                contentMap: contentMap
                            ) {
                                try yield(clipItem)
                            }
                        } catch {
                            continue
                        }
                    }
                },
                progress: progress
            )
        }
    }

    private func resolveDatabaseFile(from url: URL) throws -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let candidates = ["Storage.sqlite", "History.sqlite", "Maccy.sqlite"]
            for name in candidates {
                let check = url.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: check.path) {
                    return check
                }
            }

            let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            if let sqliteFile = contents.first(where: {
                let ext = $0.pathExtension.lowercased()
                let name = $0.lastPathComponent
                return (ext == "sqlite" || ext == "db" || ext == "storedata") &&
                    !name.contains("-wal") && !name.contains("-shm")
            }) {
                return sqliteFile
            }
            throw DatabaseError(message: "Nessun database SQLite Maccy trovato nella cartella specificata.")
        } else {
            return url
        }
    }

    private func validateTablesExist(in db: Database) throws {
        let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        let upper = Set(tables.map { $0.uppercased() })
        guard upper.contains("ZHISTORYITEM") && upper.contains("ZHISTORYITEMCONTENT") else {
            throw DatabaseError(message: "Il database selezionato non sembra essere un database valido di Maccy.")
        }
    }

    private func fetchTableColumnNames(table: String, db: Database) throws -> Set<String> {
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        guard pattern.firstMatch(in: table, range: NSRange(table.startIndex..., in: table)) != nil else {
            throw DatabaseError(message: "Nome tabella non valido")
        }

        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        let colNames = rows.compactMap { row -> String? in
            row["name"]
        }
        return Set(colNames.map { $0.uppercased() })
    }

    private func detectForeignKeyColumn(in contentColumns: Set<String>, db: Database) throws -> String {
        if contentColumns.contains("ZHISTORYITEM") {
            return "ZHISTORYITEM"
        }
        if contentColumns.contains("ZITEM") {
            return "ZITEM"
        }

        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"ZHISTORYITEMCONTENT\")")
        for row in rows {
            guard let colName = SafeRowReader.string(from: row, column: "name") else { continue }
            let upper = colName.uppercased()
            if upper == "Z_PK" || upper == "Z_ENT" || upper == "Z_OPT" {
                continue
            }
            let type: String = SafeRowReader.string(from: row, column: "type")?.uppercased() ?? ""
            if type.contains("INT") {
                return colName
            }
        }

        return "ZHISTORYITEM"
    }

    private struct RawContentRecord {
        let type: String
        let value: Data
    }

    private func fetchContentMap(fkColumn: String, in db: Database) throws -> [Int64: [RawContentRecord]] {
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        guard pattern.firstMatch(in: fkColumn, range: NSRange(fkColumn.startIndex..., in: fkColumn)) != nil else {
            throw DatabaseError(message: "Nome colonna non valido")
        }

        var map: [Int64: [RawContentRecord]] = [:]
        let sql = "SELECT \"\(fkColumn)\" AS fk, ZTYPE, ZVALUE FROM ZHISTORYITEMCONTENT WHERE ZTYPE IS NOT NULL AND ZVALUE IS NOT NULL"
        let rows = try Row.fetchAll(db, sql: sql)

        for row in rows {
            guard let fk = SafeRowReader.int64(from: row, column: "fk"),
                  let type = SafeRowReader.string(from: row, column: "ZTYPE"),
                  let data = SafeRowReader.data(from: row, column: "ZVALUE") else {
                continue
            }
            if type == "preview" || type.contains("thumbnail") {
                continue
            }
            map[fk, default: []].append(RawContentRecord(type: type, value: data))
        }

        return map
    }

    private func parseHistoryItem(
        row: Row,
        columns: Set<String>,
        contentMap: [Int64: [RawContentRecord]]
    ) throws -> ImportClipItem? {
        guard let pk = SafeRowReader.int64(from: row, column: "Z_PK") else { return nil }

        let createdAt: Date
        if columns.contains("ZFIRSTCOPIEDAT"), let coreDataTimestamp = SafeRowReader.double(from: row, column: "ZFIRSTCOPIEDAT"), coreDataTimestamp > 0 {
            createdAt = Date(timeIntervalSince1970: coreDataTimestamp + 978307200.0)
        } else if columns.contains("ZLASTCOPIEDAT"), let coreDataTimestamp = SafeRowReader.double(from: row, column: "ZLASTCOPIEDAT"), coreDataTimestamp > 0 {
            createdAt = Date(timeIntervalSince1970: coreDataTimestamp + 978307200.0)
        } else {
            createdAt = Date()
        }

        let sourceApp: String?
        if columns.contains("ZAPPLICATION") {
            sourceApp = SafeRowReader.string(from: row, column: "ZAPPLICATION")
        } else {
            sourceApp = nil
        }

        let isFavorite: Bool
        if columns.contains("ZPIN") {
            isFavorite = SafeRowReader.bool(from: row, column: "ZPIN") ?? false
        } else {
            isFavorite = false
        }

        var customName: String? = nil
        if columns.contains("ZTITLE"), let title = SafeRowReader.string(from: row, column: "ZTITLE") {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                customName = trimmed
            }
        }

        let contents = contentMap[pk] ?? []
        var representations: [String: Data] = [:]
        var extractedPlainText: String? = nil

        for item in contents {
            let uti = item.type
            representations[uti] = item.value

            if uti == "public.utf8-plain-text" && extractedPlainText == nil {
                extractedPlainText = String(decoding: item.value, as: UTF8.self)
            }
        }

        if extractedPlainText == nil, let rtfData = representations["public.rtf"], !rtfData.isEmpty {
            extractedPlainText = String(decoding: rtfData, as: UTF8.self)
        }

        guard !representations.isEmpty || !(extractedPlainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return nil
        }

        let primaryType = ClipboardMonitor.determinePrimaryType(
            plainText: extractedPlainText,
            representations: representations
        )

        let captured = CapturedClip(
            plainText: extractedPlainText,
            primaryType: primaryType,
            sourceAppBundleId: sourceApp,
            representations: representations
        )

        let hash = captured.computeContentHash()

        return ImportClipItem(
            captured: captured,
            contentHash: hash,
            customName: customName,
            isFavorite: isFavorite,
            listName: nil,
            createdAt: createdAt
        )
    }
}

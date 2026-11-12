import Foundation
import GRDB

@objc(PasteboardContentsItemTypeAndData)
internal final class PasteboardContentsItemTypeAndData: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    var type: String?
    var data: Any?

    init(type: String?, data: Any?) {
        self.type = type
        self.data = data
    }

    required init?(coder: NSCoder) {
        self.type = coder.decodeObject(of: NSString.self, forKey: "type") as String?
        let allowedClasses: [AnyClass] = [
            NSString.self,
            NSData.self,
            NSNumber.self,
            NSArray.self,
            NSDictionary.self
        ]
        self.data = coder.decodeObject(of: allowedClasses, forKey: "data")
    }

    func encode(with coder: NSCoder) {
        coder.encode(type, forKey: "type")
        coder.encode(data, forKey: "data")
    }
}

public struct CopyEmImporter: ExternalClipboardImporter {
    public let displayName: String = "Copy 'Em"
    public let sourceURL: URL

    public static let standardLocations: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.apprywhere.Copy-Em-Pro/Data/Library/Application Support", isDirectory: true),
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Copy'Em", isDirectory: true)
    ]

    public static func detectStandardDatabaseURL() -> URL? {
        let fileManager = FileManager.default
        for dir in standardLocations {
            if fileManager.fileExists(atPath: dir.path) {
                if let contents = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for item in contents {
                        let ext = item.pathExtension.lowercased()
                        let name = item.lastPathComponent.lowercased()
                        if (ext == "sqlite" || ext == "storedata" || ext == "db") &&
                            !name.contains("changelog") && !name.contains("-wal") && !name.contains("-shm") {
                            return item
                        }
                    }
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
        let (targetFileURL, assetsBaseURL) = try resolveDatabaseAndAssets(from: sourceURL)
        let sourceDB = try SourceDatabase(sourceFileURL: targetFileURL)

        return try sourceDB.queue.read { db in
            let tables = try fetchUserTables(in: db)
            guard !tables.isEmpty else {
                throw DatabaseError(message: "Database vuoto o non leggibile.")
            }

            let upperTables = Set(tables.map { $0.uppercased() })
            if upperTables.contains("ZPASTEBOARDCONTENTS") {
                return try importNativeCopyEmCoreData(
                    db: db,
                    assetsBaseURL: assetsBaseURL,
                    databaseManager: databaseManager,
                    progress: progress
                )
            } else {
                return try importFallbackGenericCopyEm(
                    db: db,
                    tables: tables,
                    assetsBaseURL: assetsBaseURL,
                    databaseManager: databaseManager,
                    progress: progress
                )
            }
        }
    }

    // MARK: - Native CoreData Schema (ZPASTEBOARDCONTENTS)
    private func importNativeCopyEmCoreData(
        db: Database,
        assetsBaseURL: URL,
        databaseManager: DatabaseManager,
        progress: ImportProgressHandler?
    ) throws -> ImportResult {
        var categoryMap: [Int64: String] = [:]
        if (try? db.tableExists("ZPASTEBOARDCONTENTSLIST")) == true {
            let listRows = try Row.fetchAll(db, sql: "SELECT Z_PK, ZNAME FROM ZPASTEBOARDCONTENTSLIST WHERE ZTRASHDATE IS NULL")
            for r in listRows {
                if let id = SafeRowReader.int64(from: r, column: "Z_PK"),
                   let name = SafeRowReader.string(from: r, column: "ZNAME") {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        categoryMap[id] = trimmed
                    }
                }
            }
        }

        var appMap: [Int64: String] = [:]
        if (try? db.tableExists("ZPASTEBOARDCONTENTSAPP")) == true {
            let appRows = try Row.fetchAll(db, sql: "SELECT Z_PK, ZBUNDLEID FROM ZPASTEBOARDCONTENTSAPP")
            for r in appRows {
                if let id = SafeRowReader.int64(from: r, column: "Z_PK"),
                   let bundleId = SafeRowReader.string(from: r, column: "ZBUNDLEID") {
                    appMap[id] = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }

        let hasItemsTable = (try? db.tableExists("ZPASTEBOARDCONTENTSITEM")) ?? false
        let totalCount = try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ZPASTEBOARDCONTENTS WHERE ZTRASHDATE IS NULL")

        let sql = """
        SELECT 
            c.Z_PK,
            c.ZNAME,
            c.ZDESC,
            c.ZCREATIONDATE,
            c.ZAPPLICATION,
            c.ZITEMSWRAPPER,
            c.ZLIST,
            c.ZTRASHDATE,
            w.ZSTRING
        FROM ZPASTEBOARDCONTENTS c
        LEFT JOIN ZPASTEBOARDCONTENTSITEMSWRAPPER w ON c.ZITEMSWRAPPER = w.Z_PK
        WHERE c.ZTRASHDATE IS NULL
        ORDER BY c.Z_PK ASC
        """
        let clipRows = try Row.fetchAll(db, sql: sql)

        let batchImporter = ClipBatchImporter()

        return try batchImporter.run(
            into: databaseManager,
            totalCount: totalCount ?? clipRows.count,
            enumerate: { yield in
                for row in clipRows {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        if let item = try parseNativeClipRow(
                            db: db,
                            row: row,
                            hasItemsTable: hasItemsTable,
                            categoryMap: categoryMap,
                            appMap: appMap,
                            assetsBaseURL: assetsBaseURL
                        ) {
                            try yield(item)
                        }
                    }
                }
            },
            progress: progress
        )
    }

    private func parseNativeClipRow(
        db: Database,
        row: Row,
        hasItemsTable: Bool,
        categoryMap: [Int64: String],
        appMap: [Int64: String],
        assetsBaseURL: URL
    ) throws -> ImportClipItem? {
        var plainText: String? = SafeRowReader.string(from: row, column: "ZSTRING")
        if let pt = plainText, pt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            plainText = nil
        }

        var representations: [String: Data] = [:]

        if hasItemsTable, let wrapperId = SafeRowReader.int64(from: row, column: "ZITEMSWRAPPER") {
            let blobs = try Data.fetchAll(
                db,
                sql: "SELECT ZTYPESANDDATA FROM ZPASTEBOARDCONTENTSITEM WHERE Z5ITEMS = ? AND ZTYPESANDDATA IS NOT NULL",
                arguments: [wrapperId]
            )
            for blob in blobs {
                let extracted = extractRepresentations(from: blob, assetsBaseURL: assetsBaseURL)
                for (uti, data) in extracted {
                    representations[uti] = data
                }
            }
        }

        if plainText == nil || plainText!.isEmpty {
            if let utf8Data = representations["public.utf8-plain-text"],
               let text = String(data: utf8Data, encoding: .utf8), !text.isEmpty {
                plainText = text
            } else if let rtfData = representations["public.rtf"],
                      let text = String(data: rtfData, encoding: .utf8), !text.isEmpty {
                plainText = text
            } else if let desc = SafeRowReader.string(from: row, column: "ZDESC"), !desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                plainText = desc.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard !representations.isEmpty || !(plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return nil
        }

        var customName: String? = nil
        if let title = SafeRowReader.string(from: row, column: "ZNAME") {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                customName = trimmed
            }
        }

        let rawListName: String?
        if let listId = SafeRowReader.int64(from: row, column: "ZLIST") {
            rawListName = categoryMap[listId]
        } else {
            rawListName = nil
        }

        let isFavorite = rawListName?.lowercased() == "favorites"
        let effectiveListName = isFavorite ? nil : rawListName

        var createdAt = Date()
        if let creationDate = SafeRowReader.double(from: row, column: "ZCREATIONDATE"), creationDate > 0 {
            if creationDate > 1_000_000_000 {
                createdAt = Date(timeIntervalSince1970: creationDate)
            } else {
                createdAt = Date(timeIntervalSince1970: creationDate + 978307200.0)
            }
        }

        let sourceApp: String?
        if let appId = SafeRowReader.int64(from: row, column: "ZAPPLICATION") {
            sourceApp = appMap[appId]
        } else {
            sourceApp = nil
        }

        let primaryType = ClipboardMonitor.determinePrimaryType(
            plainText: plainText,
            representations: representations
        )

        let captured = CapturedClip(
            plainText: plainText,
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
            listName: effectiveListName,
            createdAt: createdAt
        )
    }

    // MARK: - Payload and External Storage Extraction
    private func extractRepresentations(
        from blob: Data,
        assetsBaseURL: URL
    ) -> [String: Data] {
        var result: [String: Data] = [:]
        var payload = blob

        // CoreData "Allows External Binary Data Storage" header resolution
        if payload.count > 0 && payload[0] == 0x01 {
            payload = payload.dropFirst()
        } else if payload.count > 0 && payload[0] == 0x02 {
            let remainder = payload.dropFirst()
            if let ascii = String(data: remainder, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines), !ascii.isEmpty {
                let candidateRelativePaths = [
                    "_EXTERNAL_DATA/\(ascii)",
                    ".Copy-em-Paste_SUPPORT/_EXTERNAL_DATA/\(ascii)",
                    "Asset/\(ascii)"
                ]
                for rel in candidateRelativePaths {
                    let candidate = assetsBaseURL.appendingPathComponent(rel)
                    if let extData = safeReadFile(at: candidate, confinedTo: assetsBaseURL) {
                        payload = extData
                        break
                    }
                }
            }
        }

        // Decode via NSKeyedUnarchiver using NSSecureCoding without mutating global state
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: payload)
            unarchiver.decodingFailurePolicy = .setErrorAndReturn
            unarchiver.setClass(PasteboardContentsItemTypeAndData.self, forClassName: "PasteboardContentsItemTypeAndData")

            let allowedClasses: [AnyClass] = [NSArray.self, PasteboardContentsItemTypeAndData.self]
            if let items = try unarchiver.decodeTopLevelObject(of: allowedClasses, forKey: NSKeyedArchiveRootObjectKey) as? [PasteboardContentsItemTypeAndData] {
                for item in items {
                    guard let rawType = item.type, !rawType.isEmpty else { continue }
                    if rawType.hasPrefix("@DATA_IN_FILE ") {
                        let realUTI = String(rawType.dropFirst("@DATA_IN_FILE ".count))
                        if let d = item.data as? Data, let refStr = String(data: d, encoding: .utf8) {
                            let cleanRef = refStr.replacingOccurrences(of: "local:///", with: "")
                                .components(separatedBy: "?").first ?? ""
                            if !cleanRef.isEmpty {
                                let candidateRelativePaths = [
                                    "Asset/\(cleanRef)",
                                    cleanRef,
                                    ".Copy-em-Paste_SUPPORT/_EXTERNAL_DATA/\(cleanRef)",
                                    "_EXTERNAL_DATA/\(cleanRef)"
                                ]
                                for rel in candidateRelativePaths {
                                    let candidate = assetsBaseURL.appendingPathComponent(rel)
                                    if let fileData = safeReadFile(at: candidate, confinedTo: assetsBaseURL) {
                                        result[realUTI] = fileData
                                        break
                                    }
                                }
                            }
                        }
                    } else if let d = item.data as? Data {
                        result[rawType] = d
                    } else if let s = item.data as? String {
                        result[rawType] = Data(s.utf8)
                    }
                }
            }
        } catch {
            // Non-archive or unreadable payload; fallback continues
        }

        // Direct image magic header fallback
        if result.isEmpty && payload.count >= 4 {
            if payload[0] == 0x89 && payload[1] == 0x50 && payload[2] == 0x4E && payload[3] == 0x47 {
                result["public.png"] = payload
            } else if ((payload[0] == 0x49 && payload[1] == 0x49) || (payload[0] == 0x4D && payload[1] == 0x4D)) {
                result["public.tiff"] = payload
            }
        }

        return result
    }

    // MARK: - Safe File Access (Confinement & Anti-OOM)
    private func safeReadFile(
        at candidateURL: URL,
        confinedTo baseURL: URL,
        maxSizeBytes: Int = 100 * 1024 * 1024
    ) -> Data? {
        let resolvedBase = baseURL.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFile = candidateURL.standardizedFileURL.resolvingSymlinksInPath()

        let basePrefix = resolvedBase.path.hasSuffix("/") ? resolvedBase.path : resolvedBase.path + "/"
        guard resolvedFile.path.hasPrefix(basePrefix) else {
            return nil
        }

        guard let values = try? resolvedFile.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size <= maxSizeBytes else {
            return nil
        }

        return try? Data(contentsOf: resolvedFile)
    }

    // MARK: - Fallback Generic Schema (ZCLIP / Custom)
    private func importFallbackGenericCopyEm(
        db: Database,
        tables: [String],
        assetsBaseURL: URL,
        databaseManager: DatabaseManager,
        progress: ImportProgressHandler?
    ) throws -> ImportResult {
        let clipTable = try detectClipTable(from: tables, in: db)
        let columns = try fetchTableColumnNames(table: clipTable, db: db)

        let categoryMap = try detectCategories(from: tables, in: db)
        let joinMap = try detectJoinTableMappings(from: tables, in: db)

        let batchImporter = ClipBatchImporter()

        return try batchImporter.run(
            into: databaseManager,
            totalCount: nil,
            enumerate: { yield in
                let sql = "SELECT * FROM \"\(clipTable)\""
                let rows = try Row.fetchAll(db, sql: sql)

                for row in rows {
                    try Task.checkCancellation()
                    try autoreleasepool {
                        if let item = try parseFallbackClipRow(
                            row: row,
                            columns: columns,
                            categoryMap: categoryMap,
                            joinMap: joinMap,
                            assetsBaseURL: assetsBaseURL
                        ) {
                            try yield(item)
                        }
                    }
                }
            },
            progress: progress
        )
    }

    private func parseFallbackClipRow(
        row: Row,
        columns: [String: String],
        categoryMap: [Int64: String],
        joinMap: [Int64: Int64],
        assetsBaseURL: URL
    ) throws -> ImportClipItem? {
        let contentCol = columns.keys.first(where: {
            $0.contains("CONTENT") || $0.contains("VALUE") || $0.contains("TEXT") || $0.contains("DATA") || $0.contains("BODY") || $0.contains("STRING")
        }).flatMap({ columns[$0] })

        guard let contentCol else { return nil }

        var plainText: String? = nil
        var representations: [String: Data] = [:]

        if let dbValue = row[contentCol]?.databaseValue {
            if let stringVal = String.fromDatabaseValue(dbValue) {
                plainText = stringVal
                representations["public.utf8-plain-text"] = Data(stringVal.utf8)
            } else if let dataVal = Data.fromDatabaseValue(dbValue) {
                let extracted = extractRepresentations(from: dataVal, assetsBaseURL: assetsBaseURL)
                if !extracted.isEmpty {
                    representations = extracted
                    if let utf8 = extracted["public.utf8-plain-text"], let text = String(data: utf8, encoding: .utf8) {
                        plainText = text
                    }
                } else if dataVal.count >= 4 && dataVal[0] == 0x89 && dataVal[1] == 0x50 && dataVal[2] == 0x4E && dataVal[3] == 0x47 {
                    representations["public.png"] = dataVal
                    plainText = nil
                } else if dataVal.count >= 4 && ((dataVal[0] == 0x49 && dataVal[1] == 0x49) || (dataVal[0] == 0x4D && dataVal[1] == 0x4D)) {
                    representations["public.tiff"] = dataVal
                    plainText = nil
                } else {
                    let decoded = String(decoding: dataVal, as: UTF8.self)
                    let sample = dataVal.prefix(512)
                    if !sample.contains(0x00) && !decoded.isEmpty {
                        plainText = decoded
                        representations["public.utf8-plain-text"] = dataVal
                    }
                }
            }
        }

        guard !representations.isEmpty || !(plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            return nil
        }

        var customName: String? = nil
        if let titleCol = columns.keys.first(where: {
            $0.contains("TITLE") || $0.contains("LABEL") || ($0.contains("NAME") && !$0.contains("APP"))
        }).flatMap({ columns[$0] }) {
            if let title = SafeRowReader.string(from: row, column: titleCol) {
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    customName = trimmed
                }
            }
        }

        var isFavorite = false
        if let favCol = columns.keys.first(where: {
            $0.contains("STAR") || $0.contains("FAV") || $0.contains("PIN") || $0.contains("FLAG")
        }).flatMap({ columns[$0] }) {
            isFavorite = SafeRowReader.bool(from: row, column: favCol) ?? false
        }

        var createdAt = Date()
        if let dateCol = columns.keys.first(where: {
            $0.contains("CREATED") || $0.contains("DATE") || $0.contains("TIME") || $0.contains("COPIED")
        }).flatMap({ columns[$0] }) {
            if let doubleVal = SafeRowReader.double(from: row, column: dateCol), doubleVal > 0 {
                if doubleVal > 1_000_000_000 {
                    createdAt = Date(timeIntervalSince1970: doubleVal)
                } else {
                    createdAt = Date(timeIntervalSince1970: doubleVal + 978307200.0)
                }
            }
        }

        var sourceApp: String? = nil
        if let appCol = columns.keys.first(where: {
            $0.contains("APP") || $0.contains("SOURCE")
        }).flatMap({ columns[$0] }) {
            sourceApp = SafeRowReader.string(from: row, column: appCol)
        }

        var listName: String? = nil
        if let catCol = columns.keys.first(where: {
            $0.contains("CATEGOR") || $0.contains("LIST") || $0.contains("FOLDER") || $0.contains("GROUP")
        }).flatMap({ columns[$0] }) {
            if let catId = SafeRowReader.int64(from: row, column: catCol), let resolved = categoryMap[catId] {
                listName = resolved
            } else if let inlineName = SafeRowReader.string(from: row, column: catCol) {
                let trimmed = inlineName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    listName = trimmed
                }
            }
        } else if let clipId = SafeRowReader.int64(from: row, column: "Z_PK") ?? SafeRowReader.int64(from: row, column: "id"),
                  let targetCatId = joinMap[clipId], let resolved = categoryMap[targetCatId] {
            listName = resolved
        }

        let primaryType = ClipboardMonitor.determinePrimaryType(
            plainText: plainText,
            representations: representations
        )

        let captured = CapturedClip(
            plainText: plainText,
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
            listName: listName,
            createdAt: createdAt
        )
    }

    // MARK: - Resolution and Discovery Helpers
    private func resolveDatabaseAndAssets(from url: URL) throws -> (dbURL: URL, assetsBaseURL: URL) {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false

        if fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            let standardStore = url.appendingPathComponent("Copy-em-Paste.storedata")
            if fileManager.fileExists(atPath: standardStore.path) {
                return (standardStore, url)
            }

            let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            var candidates: [URL] = []
            while let candidate = enumerator?.nextObject() as? URL {
                let name = candidate.lastPathComponent.lowercased()
                let ext = candidate.pathExtension.lowercased()
                let path = candidate.path.lowercased()

                if path.contains("/asset/") || path.contains("/_external_data/") {
                    continue
                }
                if name.contains("changelog") || name.contains("changes") || name.contains("vectorclock") {
                    continue
                }
                if name.contains("-wal") || name.contains("-shm") {
                    continue
                }

                if ext == "storedata" || ext == "sqlite" || ext == "db" {
                    candidates.append(candidate)
                }
            }

            candidates.sort { a, b in
                func score(_ u: URL) -> Int {
                    let n = u.lastPathComponent.lowercased()
                    let e = u.pathExtension.lowercased()
                    var s = 0
                    if n.contains("copy-em-paste") || n.contains("copy'em") || n.contains("copyem") { s += 100 }
                    if e == "storedata" { s += 50 }
                    else if e == "sqlite" { s += 20 }
                    else if e == "db" { s += 10 }
                    return s
                }
                return score(a) > score(b)
            }

            if let best = candidates.first {
                return (best, url)
            }

            throw DatabaseError(message: "Nessun database Copy 'Em valido trovato nella cartella selezionata.")
        } else {
            let assetsDir = url.deletingLastPathComponent()
            return (url, assetsDir)
        }
    }

    private func fetchUserTables(in db: Database) throws -> [String] {
        let raw = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        return raw.filter { name in
            let upper = name.uppercased()
            return !upper.hasPrefix("SQLITE_") &&
                !upper.hasPrefix("Z_METADATA") &&
                !upper.hasPrefix("Z_PRIMARYKEY") &&
                !upper.hasPrefix("Z_MODELCACHE") &&
                !upper.hasPrefix("ACHANGE") &&
                !upper.hasPrefix("ATRANSACTION") &&
                !upper.hasPrefix("CHANGES") &&
                !upper.hasPrefix("VECTORCLOCK") &&
                !isJoinTable(name)
        }
    }

    private func isJoinTable(_ name: String) -> Bool {
        let pattern = try? NSRegularExpression(pattern: "^Z_[0-9]+.*$", options: .caseInsensitive)
        return pattern?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private func validateIdentifier(_ name: String) throws {
        let pattern = try NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        guard pattern.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else {
            throw DatabaseError(message: "Identificatore SQL non valido: \(name)")
        }
    }

    private func detectClipTable(from tables: [String], in db: Database) throws -> String {
        let clipKeywords = ["ZCLIP", "CLIP", "ZCLIPS", "CLIPS", "ZHISTORYITEM", "ZHISTORY", "HISTORYITEM"]
        for kw in clipKeywords {
            if let found = tables.first(where: { $0.uppercased() == kw }) {
                try validateIdentifier(found)
                return found
            }
        }

        for table in tables {
            if table.uppercased().contains("CLIP") {
                try validateIdentifier(table)
                return table
            }
        }

        var maxCount = -1
        var largestTable: String? = nil
        for table in tables {
            guard (try? validateIdentifier(table)) != nil else { continue }
            if let count = try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \"\(table)\""), count > maxCount {
                maxCount = count
                largestTable = table
            }
        }

        if let largestTable {
            try validateIdentifier(largestTable)
            return largestTable
        }

        throw DatabaseError(message: "Impossibile identificare la tabella delle clip in Copy 'Em.")
    }

    private func fetchTableColumnNames(table: String, db: Database) throws -> [String: String] {
        try validateIdentifier(table)
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\"\(table)\")")
        var dict: [String: String] = [:]
        for row in rows {
            if let name = SafeRowReader.string(from: row, column: "name") {
                dict[name.uppercased()] = name
            }
        }
        return dict
    }

    private func detectCategories(from tables: [String], in db: Database) throws -> [Int64: String] {
        guard let catTable = tables.first(where: {
            let u = $0.uppercased()
            return u.contains("CATEGOR") || u.contains("LIST") || u.contains("FOLDER") || u.contains("GROUP")
        }) else {
            return [:]
        }

        try validateIdentifier(catTable)
        let catColumns = try fetchTableColumnNames(table: catTable, db: db)
        guard let nameCol = catColumns.keys.first(where: {
            $0.contains("NAME") || $0.contains("TITLE") || $0.contains("LABEL")
        }).flatMap({ catColumns[$0] }) else {
            return [:]
        }
        try validateIdentifier(nameCol)

        let idCol = catColumns.keys.first(where: {
            $0 == "Z_PK" || $0 == "ID" || $0.contains("ID")
        }).flatMap({ catColumns[$0] }) ?? "rowid"
        try validateIdentifier(idCol)

        let rows = try Row.fetchAll(db, sql: "SELECT \"\(idCol)\" AS id, \"\(nameCol)\" AS name FROM \"\(catTable)\"")
        var map: [Int64: String] = [:]
        for row in rows {
            if let id = SafeRowReader.int64(from: row, column: "id"),
               let name = SafeRowReader.string(from: row, column: "name") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    map[id] = trimmed
                }
            }
        }
        return map
    }

    private func detectJoinTableMappings(from tables: [String], in db: Database) throws -> [Int64: Int64] {
        let allTables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        guard let joinTable = allTables.first(where: { isJoinTable($0) || $0.contains("CLIP_LIST") }) else {
            return [:]
        }

        guard (try? validateIdentifier(joinTable)) != nil else { return [:] }
        let cols = try fetchTableColumnNames(table: joinTable, db: db)
        let intCols = cols.values.filter { $0.uppercased().contains("CLIP") || $0.uppercased().contains("LIST") || $0.uppercased().contains("CATEGOR") }
        guard intCols.count >= 2 else { return [:] }

        let clipCol = intCols.first { $0.uppercased().contains("CLIP") } ?? intCols[0]
        let listCol = intCols.first { $0 != clipCol } ?? intCols[1]

        let rows = try Row.fetchAll(db, sql: "SELECT \"\(clipCol)\" AS cid, \"\(listCol)\" AS lid FROM \"\(joinTable)\"")
        var map: [Int64: Int64] = [:]
        for r in rows {
            if let cid = SafeRowReader.int64(from: r, column: "cid"),
               let lid = SafeRowReader.int64(from: r, column: "lid") {
                map[cid] = lid
            }
        }
        return map
    }
}

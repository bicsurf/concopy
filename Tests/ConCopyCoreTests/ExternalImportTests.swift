import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

final class ExternalImportTests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyImportTests_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempDir)
    }

    override func tearDownWithError() throws {
        databaseManager = nil
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Maccy Import Test
    func testMaccyImporterFullLifecycle() throws {
        let maccyDBURL = tempDir.appendingPathComponent("MaccyTest.sqlite")
        let sourceQueue = try DatabaseQueue(path: maccyDBURL.path)

        try sourceQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE ZHISTORYITEM (
                Z_PK INTEGER PRIMARY KEY,
                ZFIRSTCOPIEDAT REAL,
                ZLASTCOPIEDAT REAL,
                ZAPPLICATION TEXT,
                ZPIN INTEGER,
                ZTITLE TEXT
            );

            CREATE TABLE ZHISTORYITEMCONTENT (
                Z_PK INTEGER PRIMARY KEY,
                ZHISTORYITEM INTEGER,
                ZTYPE TEXT,
                ZVALUE BLOB
            );
            """)

            let coreDataTime = 753192000.0 // 2024-11-13 approx
            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEM (Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE)
                VALUES (1, ?, ?, 'com.apple.Safari', 1, 'Custom Maccy Title');
                """,
                arguments: [coreDataTime, coreDataTime]
            )

            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEMCONTENT (Z_PK, ZHISTORYITEM, ZTYPE, ZVALUE)
                VALUES (1, 1, 'public.utf8-plain-text', ?);
                """,
                arguments: [Data("Safari plain text clip from Maccy".utf8)]
            )

            // Image item
            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEM (Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE)
                VALUES (2, ?, ?, 'com.apple.Preview', 0, NULL);
                """,
                arguments: [coreDataTime, coreDataTime]
            )

            let dummyPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])
            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEMCONTENT (Z_PK, ZHISTORYITEM, ZTYPE, ZVALUE)
                VALUES (2, 2, 'public.png', ?);
                """,
                arguments: [dummyPNG]
            )
        }

        let importer = MaccyImporter(sourceURL: maccyDBURL)
        final class ProgressBox: @unchecked Sendable {
            var items: [ImportProgress] = []
            private let lock = NSLock()
            func add(_ p: ImportProgress) {
                lock.lock()
                defer { lock.unlock() }
                items.append(p)
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return items.count
            }
        }
        let progressBox = ProgressBox()

        let result = try importer.importClips(into: databaseManager) { progress in
            progressBox.add(progress)
        }

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.mergedDuplicatesCount, 0)
        XCTAssertEqual(result.errorsCount, 0)
        XCTAssertGreaterThan(progressBox.count, 0)

        // Verify FTS5 indexing on plainText and customName
        let ftsPlainText = try databaseManager.searchClips(query: "Safari")
        XCTAssertEqual(ftsPlainText.count, 1)
        XCTAssertEqual(ftsPlainText.first?.plainText, "Safari plain text clip from Maccy")
        XCTAssertEqual(ftsPlainText.first?.customName, "Custom Maccy Title")
        XCTAssertEqual(ftsPlainText.first?.isFavorite, true)
        XCTAssertEqual(ftsPlainText.first?.sourceAppBundleId, "com.apple.Safari")

        // Verify date conversion (CoreData epoch + 978307200)
        let expectedDate = Date(timeIntervalSince1970: 753192000.0 + 978307200.0)
        if let importedDate = ftsPlainText.first?.createdAt {
            XCTAssertEqual(importedDate.timeIntervalSince1970, expectedDate.timeIntervalSince1970, accuracy: 1.0)
        }

        let ftsCustomTitle = try databaseManager.searchClips(query: "Custom")
        XCTAssertEqual(ftsCustomTitle.count, 1)
        XCTAssertEqual(ftsCustomTitle.first?.customName, "Custom Maccy Title")

        // Verify Image item
        let allClips = try databaseManager.searchClips()
        XCTAssertEqual(allClips.count, 2)
        let imgClip = allClips.first { $0.primaryType == .image }
        XCTAssertNotNil(imgClip)
        XCTAssertFalse(imgClip?.isFavorite ?? true)
    }

    // MARK: - 2. Copy 'Em Import with Lists Test
    func testCopyEmImporterWithListsAndCustomName() throws {
        let copyEmDBURL = tempDir.appendingPathComponent("CopyEmTest.sqlite")
        let sourceQueue = try DatabaseQueue(path: copyEmDBURL.path)

        try sourceQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE ZCATEGORY (
                Z_PK INTEGER PRIMARY KEY,
                ZNAME TEXT
            );

            CREATE TABLE ZCLIP (
                Z_PK INTEGER PRIMARY KEY,
                ZCONTENT TEXT,
                ZTITLE TEXT,
                ZSTARRED INTEGER,
                ZCREATED REAL,
                ZCATEGORY INTEGER
            );
            """)

            try db.execute(
                sql: "INSERT INTO ZCATEGORY (Z_PK, ZNAME) VALUES (1, 'Development Tools');"
            )

            let unixTimestamp = 1731499200.0
            try db.execute(
                sql: """
                INSERT INTO ZCLIP (Z_PK, ZCONTENT, ZTITLE, ZSTARRED, ZCREATED, ZCATEGORY)
                VALUES (1, 'git commit -m \"feat: new feature\"', 'Git Commit Template', 1, ?, 1);
                """,
                arguments: [unixTimestamp]
            )

            // Distinct image clips to verify no hash collision
            let png1 = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03, 0x04])
            let png2 = Data([0x89, 0x50, 0x4E, 0x47, 0x05, 0x06, 0x07, 0x08])

            try db.execute(
                sql: "INSERT INTO ZCLIP (Z_PK, ZCONTENT, ZTITLE, ZSTARRED, ZCREATED, ZCATEGORY) VALUES (2, ?, 'Img 1', 0, ?, 1);",
                arguments: [png1, unixTimestamp]
            )
            try db.execute(
                sql: "INSERT INTO ZCLIP (Z_PK, ZCONTENT, ZTITLE, ZSTARRED, ZCREATED, ZCATEGORY) VALUES (3, ?, 'Img 2', 0, ?, 1);",
                arguments: [png2, unixTimestamp]
            )
        }

        let importer = CopyEmImporter(sourceURL: copyEmDBURL)
        let result = try importer.importClips(into: databaseManager, progress: nil)

        XCTAssertEqual(result.importedCount, 3)
        XCTAssertEqual(result.createdListsCount, 1)
        XCTAssertEqual(result.errorsCount, 0)

        // Verify distinct images imported
        let allClips = try databaseManager.searchClips()
        XCTAssertEqual(allClips.count, 3)
        let images = allClips.filter { $0.primaryType == .image }
        XCTAssertEqual(images.count, 2)
        XCTAssertNotEqual(images[0].contentHash, images[1].contentHash)

        // Verify list created
        let lists = try databaseManager.fetchLists()
        XCTAssertEqual(lists.count, 1)
        XCTAssertEqual(lists.first?.name, "Development Tools")

        // Verify clips assigned to list
        let clipsInList = try databaseManager.searchClips(listId: lists.first?.id)
        XCTAssertEqual(clipsInList.count, 3)
        let clip = try XCTUnwrap(clipsInList.first { $0.customName == "Git Commit Template" })
        XCTAssertEqual(clip.customName, "Git Commit Template")
        XCTAssertEqual(clip.isFavorite, true)
        XCTAssertEqual(clip.listId, lists.first?.id)

        // Verify FTS5 search
        let ftsSearch = try databaseManager.searchClips(query: "Template")
        XCTAssertEqual(ftsSearch.count, 1)
    }

    // MARK: - 3. Deduplication and Non-Destructive Merge Test
    func testDeduplicationAndConservativeMerge() throws {
        // Step 1: Pre-populate ConCopy with a clip lacking favorite and customName
        let existingCaptured = CapturedClip(
            plainText: "Shared text content across clipboard managers",
            primaryType: .text,
            sourceAppBundleId: "com.apple.Notes"
        )
        let localClip = try databaseManager.ingestCapturedClip(existingCaptured)
        XCTAssertFalse(localClip.isFavorite)
        XCTAssertNil(localClip.customName)
        XCTAssertNil(localClip.listId)

        // Step 2: Prepare Maccy DB containing the exact same text, but marked pinned with a title
        let maccyDBURL = tempDir.appendingPathComponent("MaccyDedup.sqlite")
        let sourceQueue = try DatabaseQueue(path: maccyDBURL.path)

        try sourceQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE ZHISTORYITEM (
                Z_PK INTEGER PRIMARY KEY,
                ZFIRSTCOPIEDAT REAL,
                ZLASTCOPIEDAT REAL,
                ZAPPLICATION TEXT,
                ZPIN INTEGER,
                ZTITLE TEXT
            );

            CREATE TABLE ZHISTORYITEMCONTENT (
                Z_PK INTEGER PRIMARY KEY,
                ZHISTORYITEM INTEGER,
                ZTYPE TEXT,
                ZVALUE BLOB
            );
            """)

            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEM (Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE)
                VALUES (1, 753192000.0, 753192000.0, 'com.apple.Safari', 1, 'Preserved Title From Maccy');
                """
            )

            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEMCONTENT (Z_PK, ZHISTORYITEM, ZTYPE, ZVALUE)
                VALUES (1, 1, 'public.utf8-plain-text', ?);
                """,
                arguments: [Data("Shared text content across clipboard managers".utf8)]
            )
        }

        // First import pass
        let importer = MaccyImporter(sourceURL: maccyDBURL)
        let result1 = try importer.importClips(into: databaseManager, progress: nil)

        XCTAssertEqual(result1.importedCount, 0)
        XCTAssertEqual(result1.mergedDuplicatesCount, 1)

        // Ensure no new row was created
        let allClipsAfterFirst = try databaseManager.searchClips()
        XCTAssertEqual(allClipsAfterFirst.count, 1)

        // Ensure metadata was merged conservatively
        let mergedClip = try XCTUnwrap(databaseManager.fetchClip(id: localClip.id))
        XCTAssertTrue(mergedClip.isFavorite)
        XCTAssertEqual(mergedClip.customName, "Preserved Title From Maccy")
        // Original sourceAppBundleId must NOT be overwritten
        XCTAssertEqual(mergedClip.sourceAppBundleId, "com.apple.Notes")

        // Second import pass of the exact same database
        let result2 = try importer.importClips(into: databaseManager, progress: nil)

        XCTAssertEqual(result2.importedCount, 0)
        XCTAssertEqual(result2.mergedDuplicatesCount, 1)

        let allClipsAfterSecond = try databaseManager.searchClips()
        XCTAssertEqual(allClipsAfterSecond.count, 1)
        let finalClip = try XCTUnwrap(databaseManager.fetchClip(id: localClip.id))
        XCTAssertTrue(finalClip.isFavorite)
        XCTAssertEqual(finalClip.customName, "Preserved Title From Maccy")
    }

    // MARK: - 4. Dynamic Heterogeneous SQLite Types Test (SafeRowReader)
    func testDynamicHeterogeneousTypesDoesNotCrash() throws {
        let maccyDBURL = tempDir.appendingPathComponent("MaccyHeterogeneous.sqlite")
        let sourceQueue = try DatabaseQueue(path: maccyDBURL.path)

        try sourceQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE ZHISTORYITEM (
                Z_PK INTEGER PRIMARY KEY,
                ZFIRSTCOPIEDAT NUMERIC,
                ZLASTCOPIEDAT NUMERIC,
                ZAPPLICATION TEXT,
                ZPIN BLOB,
                ZTITLE NUMERIC
            );

            CREATE TABLE ZHISTORYITEMCONTENT (
                Z_PK INTEGER PRIMARY KEY,
                ZHISTORYITEM INTEGER,
                ZTYPE TEXT,
                ZVALUE BLOB
            );
            """)

            // Row 1: ZPIN is a string "pin-label", ZTITLE is an integer 12345, timestamp is text "753192000"
            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEM (Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE)
                VALUES (1, '753192000.0', '753192000.0', 'com.apple.Safari', 'pinned_text_marker', 12345);
                """
            )

            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEMCONTENT (Z_PK, ZHISTORYITEM, ZTYPE, ZVALUE)
                VALUES (1, 1, 'public.utf8-plain-text', ?);
                """,
                arguments: [Data("Clip with string pin and numeric title".utf8)]
            )

            // Row 2: ZPIN is int 0 (unpinned), ZTITLE is null, timestamp is double
            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEM (Z_PK, ZFIRSTCOPIEDAT, ZLASTCOPIEDAT, ZAPPLICATION, ZPIN, ZTITLE)
                VALUES (2, 753192000.0, 753192000.0, 'com.apple.Finder', 0, NULL);
                """
            )

            try db.execute(
                sql: """
                INSERT INTO ZHISTORYITEMCONTENT (Z_PK, ZHISTORYITEM, ZTYPE, ZVALUE)
                VALUES (2, 2, 'public.utf8-plain-text', ?);
                """,
                arguments: [Data("Clip with zero int pin".utf8)]
            )
        }

        let importer = MaccyImporter(sourceURL: maccyDBURL)
        let result = try importer.importClips(into: databaseManager, progress: nil)

        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.errorsCount, 0)

        let clips = try databaseManager.searchClips()
        let pinnedClip = try XCTUnwrap(clips.first { $0.plainText?.contains("string pin") == true })
        XCTAssertTrue(pinnedClip.isFavorite)
        XCTAssertEqual(pinnedClip.customName, "12345")

        let unpinnedClip = try XCTUnwrap(clips.first { $0.plainText?.contains("zero int") == true })
        XCTAssertFalse(unpinnedClip.isFavorite)
        XCTAssertNil(unpinnedClip.customName)
    }

    // MARK: - 5. Native Copy 'Em CoreData .cep Package Test
    func testCopyEmImporterNativeCepBundle() throws {
        let cepDir = tempDir.appendingPathComponent("MockExport.cep", isDirectory: true)
        try FileManager.default.createDirectory(at: cepDir, withIntermediateDirectories: true)

        // Add dummy ChangeLog.db to ensure importer ignores it and chooses Copy-em-Paste.storedata
        let changeLogURL = cepDir.appendingPathComponent("ChangeLog.db")
        let changeLogQueue = try DatabaseQueue(path: changeLogURL.path)
        try changeLogQueue.write { db in
            try db.execute(sql: "CREATE TABLE Changes (id INTEGER PRIMARY KEY, serializedData BLOB);")
            try db.execute(sql: "INSERT INTO Changes (id, serializedData) VALUES (1, NULL);")
        }

        // Add Asset directory with an image
        let assetSubDir = cepDir.appendingPathComponent("Asset/MOCK_UUID", isDirectory: true)
        try FileManager.default.createDirectory(at: assetSubDir, withIntermediateDirectories: true)
        let mockPNG = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xAA, 0xBB, 0xCC, 0xDD])
        try mockPNG.write(to: assetSubDir.appendingPathComponent("sample.png"))

        // Create Copy-em-Paste.storedata
        let storeURL = cepDir.appendingPathComponent("Copy-em-Paste.storedata")
        let storeQueue = try DatabaseQueue(path: storeURL.path)

        try storeQueue.write { db in
            try db.execute(sql: """
            CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY, Z_NAME VARCHAR, Z_SUPER INTEGER, Z_MAX INTEGER);
            INSERT INTO Z_PRIMARYKEY VALUES (1, 'PasteboardContents', 0, 10);
            INSERT INTO Z_PRIMARYKEY VALUES (2, 'PasteboardContentsList', 0, 5);

            CREATE TABLE Z_METADATA (Z_VERSION INTEGER PRIMARY KEY, Z_UUID VARCHAR, Z_PLIST BLOB);
            INSERT INTO Z_METADATA VALUES (1, 'mock-uuid', NULL);

            CREATE TABLE ZPASTEBOARDCONTENTSLIST (
                Z_PK INTEGER PRIMARY KEY,
                ZNAME VARCHAR,
                ZTRASHDATE TIMESTAMP
            );
            INSERT INTO ZPASTEBOARDCONTENTSLIST VALUES (1, 'Favorites', NULL);
            INSERT INTO ZPASTEBOARDCONTENTSLIST VALUES (2, 'Dev Commands', NULL);

            CREATE TABLE ZPASTEBOARDCONTENTSAPP (
                Z_PK INTEGER PRIMARY KEY,
                ZBUNDLEID VARCHAR
            );
            INSERT INTO ZPASTEBOARDCONTENTSAPP VALUES (1, 'com.apple.Terminal');

            CREATE TABLE ZPASTEBOARDCONTENTSITEMSWRAPPER (
                Z_PK INTEGER PRIMARY KEY,
                ZSTRING VARCHAR
            );
            INSERT INTO ZPASTEBOARDCONTENTSITEMSWRAPPER VALUES (1, 'brew install swiftlint');
            INSERT INTO ZPASTEBOARDCONTENTSITEMSWRAPPER VALUES (2, NULL); -- Image clip
            INSERT INTO ZPASTEBOARDCONTENTSITEMSWRAPPER VALUES (3, 'trashed clip text');

            CREATE TABLE ZPASTEBOARDCONTENTSITEM (
                Z_PK INTEGER PRIMARY KEY,
                Z5ITEMS INTEGER,
                ZTYPESANDDATA BLOB
            );

            CREATE TABLE ZPASTEBOARDCONTENTS (
                Z_PK INTEGER PRIMARY KEY,
                ZNAME VARCHAR,
                ZDESC VARCHAR,
                ZCREATIONDATE TIMESTAMP,
                ZAPPLICATION INTEGER,
                ZITEMSWRAPPER INTEGER,
                ZLIST INTEGER,
                ZTRASHDATE TIMESTAMP
            );
            """)

            // Clip 1: Active text clip in 'Dev Commands' list
            let textItem = PasteboardContentsItemTypeAndData(
                type: "public.utf8-plain-text",
                data: Data("brew install swiftlint".utf8)
            )
            let textArchiver = NSKeyedArchiver(requiringSecureCoding: false)
            textArchiver.encode([textItem], forKey: NSKeyedArchiveRootObjectKey)
            let textBlob = textArchiver.encodedData

            try db.execute(
                sql: "INSERT INTO ZPASTEBOARDCONTENTSITEM (Z_PK, Z5ITEMS, ZTYPESANDDATA) VALUES (1, 1, ?);",
                arguments: [textBlob]
            )

            try db.execute(sql: """
            INSERT INTO ZPASTEBOARDCONTENTS (Z_PK, ZNAME, ZDESC, ZCREATIONDATE, ZAPPLICATION, ZITEMSWRAPPER, ZLIST, ZTRASHDATE)
            VALUES (1, 'Brew Swiftlint', 'brew command', 753192000.0, 1, 1, 2, NULL);
            """)

            // Clip 2: Active image clip referencing Asset via @DATA_IN_FILE in 'Favorites'
            let imageRefData = Data("local:///MOCK_UUID/sample.png?referrer=1".utf8)
            let imageItem = PasteboardContentsItemTypeAndData(
                type: "@DATA_IN_FILE public.png",
                data: imageRefData
            )
            let imgArchiver = NSKeyedArchiver(requiringSecureCoding: false)
            imgArchiver.encode([imageItem], forKey: NSKeyedArchiveRootObjectKey)
            let imgBlob = imgArchiver.encodedData

            try db.execute(
                sql: "INSERT INTO ZPASTEBOARDCONTENTSITEM (Z_PK, Z5ITEMS, ZTYPESANDDATA) VALUES (2, 2, ?);",
                arguments: [imgBlob]
            )

            try db.execute(sql: """
            INSERT INTO ZPASTEBOARDCONTENTS (Z_PK, ZNAME, ZDESC, ZCREATIONDATE, ZAPPLICATION, ZITEMSWRAPPER, ZLIST, ZTRASHDATE)
            VALUES (2, NULL, NULL, 753192000.0, 1, 2, 1, NULL);
            """)

            // Clip 3: Trashed clip (should be skipped!)
            try db.execute(sql: """
            INSERT INTO ZPASTEBOARDCONTENTS (Z_PK, ZNAME, ZDESC, ZCREATIONDATE, ZAPPLICATION, ZITEMSWRAPPER, ZLIST, ZTRASHDATE)
            VALUES (3, 'Trash Title', 'trash desc', 753192000.0, 1, 3, 2, 753193000.0);
            """)

            // Clip 4: Malicious path traversal attempt (should be rejected safely)
            let traversalRefData = Data("local:///../../../../etc/passwd".utf8)
            let traversalItem = PasteboardContentsItemTypeAndData(
                type: "@DATA_IN_FILE public.data",
                data: traversalRefData
            )
            let traversalArchiver = NSKeyedArchiver(requiringSecureCoding: false)
            traversalArchiver.encode([traversalItem], forKey: NSKeyedArchiveRootObjectKey)
            let traversalBlob = traversalArchiver.encodedData

            try db.execute(
                sql: "INSERT INTO ZPASTEBOARDCONTENTSITEM (Z_PK, Z5ITEMS, ZTYPESANDDATA) VALUES (4, 4, ?);",
                arguments: [traversalBlob]
            )

            try db.execute(sql: """
            INSERT INTO ZPASTEBOARDCONTENTS (Z_PK, ZNAME, ZDESC, ZCREATIONDATE, ZAPPLICATION, ZITEMSWRAPPER, ZLIST, ZTRASHDATE)
            VALUES (4, NULL, NULL, 753192000.0, 1, 4, NULL, NULL);
            """)
        }

        // Import passing the .cep directory bundle directly
        let importer = CopyEmImporter(sourceURL: cepDir)
        let result = try importer.importClips(into: databaseManager, progress: nil)

        // Only clips 1 and 2 should be imported (clip 3 is trashed, clip 4 has traversal rejected and no text)
        XCTAssertEqual(result.importedCount, 2)
        XCTAssertEqual(result.createdListsCount, 1) // 'Dev Commands' created; 'Favorites' mapped to isFavorite
        XCTAssertEqual(result.errorsCount, 0)

        let clips = try databaseManager.searchClips()
        XCTAssertEqual(clips.count, 2)

        // Clip 1 assertions
        let textClip = try XCTUnwrap(clips.first { $0.customName == "Brew Swiftlint" })
        XCTAssertEqual(textClip.plainText, "brew install swiftlint")
        XCTAssertFalse(textClip.isFavorite)
        XCTAssertNotNil(textClip.listId)
        XCTAssertEqual(textClip.sourceAppBundleId, "com.apple.Terminal")

        // Clip 2 assertions
        let imgClip = try XCTUnwrap(clips.first { $0.primaryType == .image })
        XCTAssertTrue(imgClip.isFavorite)
        XCTAssertNil(imgClip.listId)

        // Ensure no empty clips
        for c in clips {
            let hasText = !(c.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasPayloads = try databaseManager.fetchPayloads(for: c.id).count > 0
            XCTAssertTrue(hasText || hasPayloads, "Imported clip must not be empty [Nessun contenuto]")
        }
    }

    // MARK: - 6. Real User Export Test (if present on machine)
    func testRealUserExportIfPresent() throws {
        guard let customPath = ProcessInfo.processInfo.environment["CONCOPY_TEST_CEP_PATH"],
              !customPath.isEmpty else {
            throw XCTSkip("CONCOPY_TEST_CEP_PATH environment variable not set; skipping real user export verification.")
        }

        let realExportURL = URL(fileURLWithPath: customPath)
        guard FileManager.default.fileExists(atPath: realExportURL.path) else {
            throw XCTSkip("File not found at path configured in CONCOPY_TEST_CEP_PATH: \(customPath)")
        }

        let importer = CopyEmImporter(sourceURL: realExportURL)
        let result = try importer.importClips(into: databaseManager, progress: nil)

        XCTAssertGreaterThan(result.importedCount, 0)
        XCTAssertEqual(result.errorsCount, 0)

        let clips = try databaseManager.searchClips(limit: 5000)
        XCTAssertGreaterThanOrEqual(clips.count, result.importedCount)

        // Ensure zero clips have empty content
        for c in clips {
            let hasText = !(c.plainText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasPayloads = try databaseManager.fetchPayloads(for: c.id).count > 0
            XCTAssertTrue(hasText || hasPayloads, "Clip \(c.id) must have content, not [Nessun contenuto]")
        }
    }
}

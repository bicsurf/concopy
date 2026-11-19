import XCTest
import GRDB
@testable import ConCopyCore

final class StorageTests: XCTestCase {
    private var tempBlobDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBlobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBlobDir, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempBlobDir)
    }

    override func tearDownWithError() throws {
        databaseManager = nil
        if let dir = tempBlobDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testMultiFormatInsertionAndPayloadRetrieval() throws {
        let textData = Data("Inline small text".utf8)
        let largeImageData = Data(repeating: 0x42, count: 8192)

        let captured = CapturedClip(
            plainText: "Inline small text",
            primaryType: .text,
            sourceAppBundleId: "com.apple.Notes",
            representations: [
                "public.utf8-plain-text": textData,
                "public.png": largeImageData
            ]
        )

        let clip = try databaseManager.ingestCapturedClip(captured)
        let payloads = try databaseManager.fetchPayloads(for: clip.id)

        XCTAssertEqual(payloads.count, 2)

        let textPayload = payloads.first { $0.utiType == "public.utf8-plain-text" }
        XCTAssertNotNil(textPayload)
        XCTAssertNotNil(textPayload?.inlineData)
        XCTAssertNil(textPayload?.blobFilename)
        XCTAssertEqual(textPayload?.byteSize, textData.count)

        let imagePayload = payloads.first { $0.utiType == "public.png" }
        XCTAssertNotNil(imagePayload)
        XCTAssertNil(imagePayload?.inlineData)
        XCTAssertNotNil(imagePayload?.blobFilename)
        XCTAssertEqual(imagePayload?.byteSize, 8192)

        if let textPayload {
            let loadedText = try databaseManager.loadPayloadData(for: textPayload)
            XCTAssertEqual(loadedText, textData)
        }

        if let imagePayload {
            let loadedImage = try databaseManager.loadPayloadData(for: imagePayload)
            XCTAssertEqual(loadedImage, largeImageData)
        }
    }

    func testSHA256Deduplication() throws {
        let clip1 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Unique repeated string content")
        )

        Thread.sleep(forTimeInterval: 0.05)

        let clip2 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Unique repeated string content")
        )

        XCTAssertEqual(clip1.id, clip2.id)
        XCTAssertEqual(clip1.contentHash, clip2.contentHash)
        XCTAssertGreaterThan(clip2.updatedAt, clip1.updatedAt)

        let allClips = try databaseManager.searchClips()
        XCTAssertEqual(allClips.count, 1)
    }

    func testFTS5SearchOnTextAndCustomName() throws {
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Specialized macOS Systems Architecture")
        )

        let searchPrefix = try databaseManager.searchClips(query: "Special")
        XCTAssertEqual(searchPrefix.count, 1)
        XCTAssertEqual(searchPrefix.first?.id, clip.id)

        let searchWord = try databaseManager.searchClips(query: "Architecture")
        XCTAssertEqual(searchWord.count, 1)

        let searchMiss = try databaseManager.searchClips(query: "NonExistentKeyword")
        XCTAssertTrue(searchMiss.isEmpty)

        try databaseManager.updateCustomName(clipId: clip.id, name: "Secret Blueprint")

        let searchPrefixCustom = try databaseManager.searchClips(query: "Secret")
        XCTAssertEqual(searchPrefixCustom.count, 1)

        let searchCustomName = try databaseManager.searchClips(query: "Blueprint")
        XCTAssertEqual(searchCustomName.count, 1)
        XCTAssertEqual(searchCustomName.first?.customName, "Secret Blueprint")
    }

    func testAutoStarMode() throws {
        let list = ClipListRecord(name: "Important Clips", sortOrder: 1)
        try databaseManager.saveList(list)
        try databaseManager.setAutoStarList(listId: list.id)

        let captured = CapturedClip(plainText: "Auto-starred item")
        let clip = try databaseManager.ingestCapturedClip(captured)

        XCTAssertTrue(clip.isFavorite)
        XCTAssertEqual(clip.listId, list.id)

        let fetched = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(fetched?.isFavorite, true)
        XCTAssertEqual(fetched?.listId, list.id)
    }

    func testBlobCleanupOnDeletion() throws {
        let largeData = Data(repeating: 0x99, count: 6000)
        let captured = CapturedClip(
            representations: ["public.png": largeData]
        )

        let clip = try databaseManager.ingestCapturedClip(captured)
        let payloads = try databaseManager.fetchPayloads(for: clip.id)
        let imagePayload = payloads.first { $0.utiType == "public.png" }

        guard let blobFilename = imagePayload?.blobFilename else {
            XCTFail("Blob filename should exist for large payload")
            return
        }

        let blobURL = tempBlobDir.appendingPathComponent(blobFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobURL.path))

        try databaseManager.deleteClip(clipId: clip.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: blobURL.path))
        let fetched = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNil(fetched)
    }

    func testSearchWithFilters() throws {
        let listA = ClipListRecord(name: "List A")
        let listB = ClipListRecord(name: "List B")
        try databaseManager.saveList(listA)
        try databaseManager.saveList(listB)

        let clipA = try databaseManager.ingestCapturedClip(
            CapturedClip(
                plainText: "Document for list A",
                primaryType: .text,
                sourceAppBundleId: "com.apple.Safari"
            )
        )
        // Set listId
        try databaseManager.dbWriter.write { db in
            var c = try ClipRecord.fetchOne(db, id: clipA.id)!
            c.listId = listA.id
            c.isFavorite = true
            try c.update(db)
        }

        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(
                plainText: "Document for list B",
                primaryType: .text,
                sourceAppBundleId: "com.apple.Terminal"
            )
        )

        let listAFilter = try databaseManager.searchClips(listId: listA.id)
        XCTAssertEqual(listAFilter.count, 1)
        XCTAssertEqual(listAFilter.first?.id, clipA.id)

        let favFilter = try databaseManager.searchClips(favoritesOnly: true)
        XCTAssertEqual(favFilter.count, 1)
        XCTAssertEqual(favFilter.first?.id, clipA.id)

        let bundleFilter = try databaseManager.searchClips(sourceAppBundleId: "com.apple.Safari")
        XCTAssertEqual(bundleFilter.count, 1)
        XCTAssertEqual(bundleFilter.first?.sourceAppBundleId, "com.apple.Safari")
    }

    func testPrimaryTypeDetection() {
        let textType = ClipboardMonitor.determinePrimaryType(
            plainText: "Simple string",
            representations: [:]
        )
        XCTAssertEqual(textType, .text)

        let urlType = ClipboardMonitor.determinePrimaryType(
            plainText: "https://apple.com/macos",
            representations: [:]
        )
        XCTAssertEqual(urlType, .url)

        let fileType = ClipboardMonitor.determinePrimaryType(
            plainText: "file:///Users/test/file.txt",
            representations: ["public.file-url": Data("file:///Users/test/file.txt".utf8)]
        )
        XCTAssertEqual(fileType, .file)

        let imageType = ClipboardMonitor.determinePrimaryType(
            plainText: nil,
            representations: ["public.png": Data([0x89, 0x50, 0x4E, 0x47])]
        )
        XCTAssertEqual(imageType, .image)

        let richTextType = ClipboardMonitor.determinePrimaryType(
            plainText: "Formatted",
            representations: ["public.rtf": Data("{\\rtf1 Formatted}".utf8)]
        )
        XCTAssertEqual(richTextType, .richText)
    }

    func testFTS5SanitizationWithSpecialCharacters() throws {
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Learning c++ and rust systems programming")
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Server listening on http://example.com:8080/api/v1")
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Unit testing with \"quoted strings\" and (parentheses)")
        )

        // 1. Quotes are literal parts of the query, rather than FTS syntax.
        let quotedResults = try databaseManager.searchClips(query: "\"quoted strings\"")
        XCTAssertEqual(quotedResults.count, 1)
        XCTAssertTrue(try databaseManager.searchClips(query: "\"quoted\"").isEmpty)

        // 2. Query with special characters: c++ preserves the plus signs.
        let cppResults = try databaseManager.searchClips(query: "c++")
        XCTAssertFalse(cppResults.isEmpty)
        XCTAssertTrue(cppResults.contains { $0.plainText?.contains("c++") == true })

        // 3. Query with URL, colons and slashes
        let urlResults = try databaseManager.searchClips(query: "http://example.com:8080")
        XCTAssertEqual(urlResults.count, 1)

        // 4. Query with pure symbols: ***
        let symbolResults = try databaseManager.searchClips(query: "***")
        XCTAssertTrue(symbolResults.isEmpty)

        // 5. Query with parentheses
        let parenResults = try databaseManager.searchClips(query: "(parentheses)")
        XCTAssertEqual(parenResults.count, 1)

        // 6. Query with port colon
        let portResults = try databaseManager.searchClips(query: ":8080")
        XCTAssertEqual(portResults.count, 1)
    }

    func testLiteralSearchPreservesPunctuationInMixedQueries() throws {
        let cases = [
            ("~prova", "shell ~prova path", "shell prova path"),
            ("~/Library", "open ~/Library/Preferences", "open /Library/Preferences"),
            ("c++", "Learning c++ programming", "Learning c programming"),
            ("hello@example.com", "Contact hello@example.com", "Contact hello example com"),
            ("file_name", "open file_name.txt", "open fileXname.txt"),
            ("50%", "discount 50% today", "discount 500 today"),
            (#"\temp\file"#, #"open C:\temp\file.txt"#, "open C temp file txt"),
            ("\"quoted\"", "a \"quoted\" word", "a quoted word")
        ]
        for (query, matching, nonmatching) in cases {
            let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempBlobDir)
            let expected = try db.ingestCapturedClip(CapturedClip(plainText: matching))
            _ = try db.ingestCapturedClip(CapturedClip(plainText: nonmatching))
            XCTAssertEqual(try db.searchClips(query: query).map(\.id), [expected.id], query)
            XCTAssertEqual(try db.searchClips(query: query.uppercased()).map(\.id), [expected.id], query)
        }
    }

    func testLiteralSearchEscapesWildcardsAndBackslashes() throws {
        let cases = [
            ("%", "50% discount", "ordinary text"),
            ("_", "user_name", "username"),
            (#"\"#, #"C:\Temp"#, "C Temp"),
            (#"\%_"#, #"escaped \%_ value"#, #"escaped \abcX value"#),
            ("***", "literal *** stars", "ordinary stars"),
            ("🙂", "a 🙂 symbol", "no symbol here"),
            ("' OR 1=1 --", "literal ' OR 1=1 -- string", "unrelated string")
        ]
        for (query, matching, nonmatching) in cases {
            let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempBlobDir)
            let expected = try db.ingestCapturedClip(CapturedClip(plainText: matching))
            _ = try db.ingestCapturedClip(CapturedClip(plainText: nonmatching))
            XCTAssertEqual(try db.searchClips(query: query).map(\.id), [expected.id], query)
        }
    }

    func testLiteralSearchFindsSymbolsInCustomNames() throws {
        let expected = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "first body"))
        try databaseManager.updateCustomName(clipId: expected.id, name: "~/Library/user_name 50%")
        let other = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "second body"))
        try databaseManager.updateCustomName(clipId: other.id, name: "/Library/userXname 500")

        for query in ["~/Library", "user_name", "50%", "%", "_"] {
            XCTAssertEqual(try databaseManager.searchClips(query: query).map(\.id), [expected.id], query)
        }
    }

    func testLiteralSearchRespectsFiltersOrderingAndLimit() throws {
        let list = ClipListRecord(name: "Literal search")
        try databaseManager.saveList(list)
        var records: [ClipRecord] = []
        for index in 0..<6 {
            let clip = try databaseManager.ingestCapturedClip(CapturedClip(
                plainText: "~token item \(index)",
                primaryType: index == 5 ? .image : .text,
                sourceAppBundleId: index == 4 ? "com.apple.Terminal" : "com.apple.Safari"
            ))
            try databaseManager.dbWriter.write { db in
                var stored = try XCTUnwrap(ClipRecord.fetchOne(db, id: clip.id))
                stored.listId = index == 3 ? nil : list.id
                stored.isFavorite = index != 2
                stored.manualSortIndex = index == 0 ? 10 : index
                try stored.update(db)
            }
            records.append(clip)
        }

        XCTAssertEqual(try databaseManager.searchClips(query: "~token", listId: list.id).count, 5)
        XCTAssertEqual(try databaseManager.searchClips(query: "~token", sourceAppBundleId: "com.apple.Safari").count, 5)
        XCTAssertEqual(try databaseManager.searchClips(query: "~token", primaryType: .text).count, 5)
        XCTAssertEqual(try databaseManager.searchClips(query: "~token", favoritesOnly: true).count, 5)
        let results = try databaseManager.searchClips(
            query: "~token", listId: list.id, sourceAppBundleId: "com.apple.Safari", primaryType: .text,
            favoritesOnly: true, sortMode: .manualOrder, limit: 1
        )
        XCTAssertEqual(results.map(\.id), [records[1].id])
    }

    func testWordSearchRetainsPrefixesWordOrderAndAccentedText() throws {
        let expected = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Learning Rust at the café"))
        _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Learning Swift at home"))
        for query in ["rust learn", "café rust", "cafe\u{301} rust", "  rust   learn  "] {
            XCTAssertEqual(try databaseManager.searchClips(query: query).map(\.id), [expected.id], query)
        }
    }

    func testLegacyURLNameRemainsSearchable() throws {
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(
                plainText: "https://news.ycombinator.com",
                primaryType: .url
            )
        )

        // Initially matches by URL string
        let initialSearch = try databaseManager.searchClips(query: "ycombinator")
        XCTAssertEqual(initialSearch.count, 1)
        XCTAssertEqual(initialSearch.first?.id, clip.id)

        // Names from older histories and imported archives remain compatible.
        let fetchedTitle = "Hacker News: Computer Technology and Startups"
        try databaseManager.updateCustomName(clipId: clip.id, name: fetchedTitle)

        // Verify FTS5 now indexes the new title
        let titleSearch = try databaseManager.searchClips(query: "Hacker")
        XCTAssertEqual(titleSearch.count, 1)
        XCTAssertEqual(titleSearch.first?.id, clip.id)
        XCTAssertEqual(titleSearch.first?.customName, fetchedTitle)

        // Searching for another word from the title
        let techSearch = try databaseManager.searchClips(query: "Startups")
        XCTAssertEqual(techSearch.count, 1)
        XCTAssertEqual(techSearch.first?.id, clip.id)
    }

    func testClearAllHistoryPreservesFavorites() throws {
        let normal = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Normal clip to delete"))
        let fav = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Protected favorite clip"))
        _ = try databaseManager.toggleFavorite(clipId: fav.id)

        let clearedCount = try databaseManager.clearAllHistory(preserveFavorites: true)
        XCTAssertEqual(clearedCount, 1)

        let remaining = try databaseManager.searchClips()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.id, fav.id)
        XCTAssertNil(try databaseManager.fetchClip(id: normal.id))
    }

    func testToggleFavoriteAndAssignToList() throws {
        let clip = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Favorite & List test"))
        XCTAssertFalse(clip.isFavorite)
        XCTAssertNil(clip.listId)

        // 1. Toggle favorite
        let updatedFav = try databaseManager.toggleFavorite(clipId: clip.id)
        XCTAssertTrue(updatedFav.isFavorite)

        let reloadedFav = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(reloadedFav?.isFavorite, true)

        // 2. Create list and assign
        let list = try databaseManager.createList(name: "Work Project")
        try databaseManager.assignClip(clipId: clip.id, toListId: list.id)

        let reloadedInList = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(reloadedInList?.listId, list.id)

        // 3. Search in list
        let listClips = try databaseManager.searchClips(listId: list.id)
        XCTAssertEqual(listClips.count, 1)
        XCTAssertEqual(listClips.first?.id, clip.id)

        // 4. Remove from list
        try databaseManager.assignClip(clipId: clip.id, toListId: nil)
        let unassigned = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNil(unassigned?.listId)
    }
}

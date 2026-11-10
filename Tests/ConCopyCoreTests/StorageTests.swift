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

        // 1. Quoted string query
        let quotedResults = try databaseManager.searchClips(query: "\"quoted\"")
        XCTAssertEqual(quotedResults.count, 1)

        // 2. Query with special characters: c++ (sanitized to "c"*, matches without FTS5 syntax crash)
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

    func testURLMetadataUpdateAndFTS5SearchCycle() throws {
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

        // Simulate LinkMetadataFetcher title update
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
}

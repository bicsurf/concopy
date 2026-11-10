import AppKit
import XCTest
@testable import ConCopyCore

final class Phase5Tests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyPhase5Tests_\(UUID().uuidString)")
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

    func testInPlaceTextEditorAndFTS5Update() throws {
        let initialClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "OldAlphaContent text")
        )

        let initialSearch = try databaseManager.searchClips(query: "OldAlphaContent")
        XCTAssertEqual(initialSearch.count, 1)

        // Update text in-place
        try databaseManager.updateTextContent(clipId: initialClip.id, newPlainText: "NewBetaContent updated")

        let updated = try databaseManager.fetchClip(id: initialClip.id)
        XCTAssertEqual(updated?.plainText, "NewBetaContent updated")
        XCTAssertNotEqual(updated?.contentHash, initialClip.contentHash)

        // FTS5 must find the new string
        let newSearch = try databaseManager.searchClips(query: "NewBetaContent")
        XCTAssertEqual(newSearch.count, 1)
        XCTAssertEqual(newSearch.first?.id, initialClip.id)

        // FTS5 must no longer match the old content
        let oldSearch = try databaseManager.searchClips(query: "OldAlphaContent")
        XCTAssertTrue(oldSearch.isEmpty)
    }

    func testCustomNameAndFTS5Search() throws {
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "AKIAIOSFODNN7EXAMPLE")
        )

        try databaseManager.updateCustomName(clipId: clip.id, name: "Production AWS Key")

        let searchByName = try databaseManager.searchClips(query: "Production")
        XCTAssertEqual(searchByName.count, 1)
        XCTAssertEqual(searchByName.first?.id, clip.id)
        XCTAssertEqual(searchByName.first?.customName, "Production AWS Key")

        let searchBySecondWord = try databaseManager.searchClips(query: "AWS")
        XCTAssertEqual(searchBySecondWord.count, 1)
    }

    func testLinkMetadataExtraction() {
        let fetcher = LinkMetadataFetcher()
        let sampleHTML = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Apple &amp; Swift Developers &quot;Portal&quot;</title>
            <link rel="icon" href="/static/favicon.png">
        </head>
        <body><h1>Hello</h1></body>
        </html>
        """

        let title = fetcher.extractTitle(from: sampleHTML)
        XCTAssertEqual(title, "Apple & Swift Developers \"Portal\"")

        let baseURL = URL(string: "https://developer.apple.com/news/")!
        let favicon = fetcher.extractFavicon(from: sampleHTML, baseURL: baseURL)
        XCTAssertEqual(favicon?.absoluteString, "https://developer.apple.com/static/favicon.png")
    }

    func testExportAndImportJSON() async throws {
        // Setup initial database with lists, clips, inline & blob payloads
        let list1 = try databaseManager.createList(name: "Work List")
        let list2 = try databaseManager.createList(name: "Personal List")

        let textClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Standard small text clip")
        )
        _ = try databaseManager.assignClip(clipId: textClip.id, toListId: list1.id)
        try databaseManager.updateCustomName(clipId: textClip.id, name: "Quick Note")

        let largeData = Data(repeating: 0x55, count: 6000)
        let blobClip = try databaseManager.ingestCapturedClip(
            CapturedClip(
                plainText: "Large blob payload",
                primaryType: .image,
                representations: ["public.png": largeData]
            )
        )
        _ = try databaseManager.assignClip(clipId: blobClip.id, toListId: list2.id)

        // Export archive to JSON
        let archiveURL = tempDir.appendingPathComponent("backup.json")
        let archiveManager = ArchiveManager()
        try await archiveManager.exportArchive(to: archiveURL, databaseManager: databaseManager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: archiveURL.path))
        let fileSize = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0)

        // Create new empty destination database in a fresh directory
        let newTempDir = tempDir.appendingPathComponent("NewDB_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: newTempDir, withIntermediateDirectories: true)
        let newDatabaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: newTempDir)

        // Verify destination is empty
        let initialClips = try newDatabaseManager.searchClips(query: "")
        XCTAssertEqual(initialClips.count, 0)
        let initialLists = try newDatabaseManager.fetchAllLists()
        XCTAssertEqual(initialLists.count, 0)

        // Import archive into new database
        try await archiveManager.importArchive(from: archiveURL, databaseManager: newDatabaseManager)

        // Validate restored lists
        let restoredLists = try newDatabaseManager.fetchAllLists()
        XCTAssertEqual(restoredLists.count, 2)
        XCTAssertTrue(restoredLists.contains(where: { $0.name == "Work List" }))
        XCTAssertTrue(restoredLists.contains(where: { $0.name == "Personal List" }))

        // Validate restored clips
        let restoredClips = try newDatabaseManager.searchClips(query: "")
        XCTAssertEqual(restoredClips.count, 2)

        let restoredNote = try XCTUnwrap(restoredClips.first(where: { $0.customName == "Quick Note" }))
        XCTAssertEqual(restoredNote.plainText, "Standard small text clip")
        XCTAssertTrue(restoredNote.isFavorite)

        let restoredBlobClip = try XCTUnwrap(restoredClips.first(where: { $0.primaryType == .image }))
        let payloads = try newDatabaseManager.fetchPayloads(forClipId: restoredBlobClip.id)
        let imagePayload = try XCTUnwrap(payloads.first(where: { $0.utiType == "public.png" }))
        let loadedData = try newDatabaseManager.loadPayloadData(for: imagePayload)
        XCTAssertEqual(loadedData, largeData)
    }
}

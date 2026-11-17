import AppKit
import GRDB
import XCTest

@testable import ConCopyCore

@MainActor
final class AuditDataIntegrityTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory
    private var db: DatabaseManager?
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopyAudit_\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent("blobs"))
    }
    override func tearDownWithError() throws {
        db = nil
        try? FileManager.default.removeItem(at: directory)
    }
    private func database() throws -> DatabaseManager { try XCTUnwrap(db) }
    private func capture(_ text: String) throws -> ClipRecord {
        try database().ingestCapturedClip(CapturedClip(plainText: text))
    }

    func testA02A03BinaryIdentityIgnoresLabels() throws {
        let db = try database()
        let first = try db.ingestCapturedClip(
            CapturedClip(
                plainText: "Immagine (8x8)", primaryType: .image, representations: ["public.png": Data([1, 2])]))
        let second = try db.ingestCapturedClip(
            CapturedClip(
                plainText: "Immagine (8x8)", primaryType: .image, representations: ["public.png": Data([3, 4])]))
        XCTAssertNotEqual(first.id, second.id)
        let urls = [URL(fileURLWithPath: "/a/notes.txt"), URL(fileURLWithPath: "/b/notes.txt")]
        let files = try urls.map { url in
            try db.ingestCapturedClip(
                CapturedClip(
                    plainText: "notes.txt", primaryType: .file,
                    representations: ["public.file-url": Data(url.absoluteString.utf8)]))
        }
        XCTAssertNotEqual(files[0].id, files[1].id)
        XCTAssertEqual(
            try db.ingestCapturedClip(
                CapturedClip(
                    plainText: "another label", primaryType: .image, representations: ["public.png": Data([1, 2])])
            ).id, first.id)
    }
    func testA04A15EditingPreservesSharedBlobsAndDropsOldRichFormats() throws {
        let db = try database()
        let shared = String(repeating: "x", count: 5000)
        let text = try capture(shared)
        let other = try db.ingestCapturedClip(
            CapturedClip(plainText: "other", representations: ["public.html": Data(shared.utf8)]))
        try db.updateTextContent(clipId: text.id, newPlainText: "edited")
        let sharedPayload = try XCTUnwrap(db.fetchPayloads(for: other.id).first { $0.utiType == "public.html" })
        XCTAssertEqual(try db.loadPayloadData(for: sharedPayload), Data(shared.utf8))
        let rich = try db.ingestCapturedClip(
            CapturedClip(
                plainText: "old", primaryType: .richText, representations: ["public.rtf": Data("{\\rtf1 old}".utf8)]))
        try db.updateTextContent(clipId: rich.id, newPlainText: "new")
        XCTAssertEqual(try db.fetchClip(id: rich.id)?.primaryType, .text)
        XCTAssertEqual(try db.fetchPayloads(for: rich.id).map(\.utiType), ["public.utf8-plain-text"])
    }
    func testA05FailedImportKeepsPreexistingSharedBlob() throws {
        let db = try database()
        let shared = Data(repeating: 7, count: 5000)
        let old = try db.ingestCapturedClip(CapturedClip(plainText: "old", representations: ["public.html": shared]))
        let incoming = CapturedClip(plainText: "incoming", representations: ["public.html": shared])
        XCTAssertThrowsError(
            try ClipBatchImporter().run(
                into: db, totalCount: 1,
                enumerate: { yield in
                    try yield(
                        ImportClipItem(
                            captured: incoming, contentHash: incoming.computeContentHash(), customName: nil,
                            isFavorite: false, listName: nil, createdAt: Date()))
                    throw CocoaError(.fileWriteUnknown)
                }, progress: nil))
        XCTAssertEqual(try db.searchClips().count, 1)
        let payload = try XCTUnwrap(db.fetchPayloads(for: old.id).first { $0.utiType == "public.html" })
        XCTAssertEqual(try db.loadPayloadData(for: payload), shared)
    }
    func testA09A10BackupIncludesSnippetsAndRestoresEditedClipWithoutConflict() async throws {
        let db = try database()
        let original = try capture("before")
        try db.saveSnippet(SnippetRecord(shortcut: ";email", content: "a@example.test"))
        let archive = directory.appendingPathComponent("backup.json")
        try await ArchiveManager().exportArchive(to: archive, databaseManager: db)
        let restored = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent("restored"))
        try await ArchiveManager().importArchive(from: archive, databaseManager: restored)
        XCTAssertEqual(try restored.fetchSnippets().map(\.shortcut), [";email"])
        try db.updateTextContent(clipId: original.id, newPlainText: "after")
        try await ArchiveManager().importArchive(from: archive, databaseManager: db)
        XCTAssertEqual(Set(try db.searchClips().compactMap(\.plainText)), ["before", "after"])
        XCTAssertEqual(try db.fetchClip(id: original.id)?.plainText, "after")
    }
    func testA11StreamRetainsOnlyLatestCapture() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        for i in 0..<20 {
            pasteboard.clearContents()
            pasteboard.setString("item \(i)", forType: .string)
            XCTAssertNotNil(monitor.checkForChanges())
        }
        var clips = monitor.capturedClipStream.makeAsyncIterator()
        var items = monitor.stream.makeAsyncIterator()
        let latestClip = await clips.next()
        let latestItem = await items.next()
        XCTAssertEqual(latestClip?.plainText, "item 19")
        XCTAssertEqual(latestItem?.content, "item 19")
    }
    func testA13MaccyWriteFailureRollsBackInsteadOfClaimingSuccess() async throws {
        let db = try database()
        try await db.dbWriter.write { database in
            try database.execute(
                sql:
                    "CREATE TRIGGER fail_payload BEFORE INSERT ON clip_payloads BEGIN SELECT RAISE(ABORT,'test failure'); END"
            )
        }
        let url = directory.appendingPathComponent("maccy.sqlite")
        let source = try DatabaseQueue(path: url.path)
        try await source.write { database in
            try database.execute(
                sql:
                    "CREATE TABLE ZHISTORYITEM(Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZHISTORYITEMCONTENT(ZHISTORYITEM INTEGER,ZTYPE TEXT,ZVALUE BLOB); INSERT INTO ZHISTORYITEM VALUES(1)"
            )
            try database.execute(
                sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES(1,'public.utf8-plain-text',?)",
                arguments: [Data("test".utf8)])
        }
        XCTAssertThrowsError(try MaccyImporter(sourceURL: url).importClips(into: db, progress: nil))
        XCTAssertTrue(try db.searchClips().isEmpty)
    }
    func testA14NumericCoercionRejectsOverflowAndInfinity() {
        for value in [1e100, -1e100, Double.infinity, -Double.infinity] {
            XCTAssertNil(SafeRowReader.int64(from: Row(["value": value]), column: "value"))
        }
        XCTAssertEqual(SafeRowReader.int64(from: Row(["value": 42.0]), column: "value"), 42)
    }
    func testA16RecaptureMergesNewRichRepresentation() throws {
        let db = try database()
        let plain = try capture("same")
        let rich = try db.ingestCapturedClip(
            CapturedClip(
                plainText: "same", primaryType: .richText, representations: ["public.rtf": Data("{\\rtf1 same}".utf8)]))
        XCTAssertEqual(rich.id, plain.id)
        XCTAssertTrue(try db.fetchPayloads(for: plain.id).contains { $0.utiType == "public.rtf" })
    }
    func testA21OversizedImportDoesNotCreateEmptyClip() throws {
        let db = try database()
        let captured = CapturedClip(
            primaryType: .image,
            representations: ["public.png": Data(repeating: 1, count: ClipBatchImporter.maxBlobSizeBytes + 1)])
        let result = try ClipBatchImporter().run(
            into: db, totalCount: 1,
            enumerate: { yield in
                try yield(
                    ImportClipItem(
                        captured: captured, contentHash: captured.computeContentHash(), customName: nil,
                        isFavorite: false, listName: nil, createdAt: Date()))
            }, progress: nil)
        XCTAssertEqual(result.importedCount, 0)
        XCTAssertEqual(result.errorsCount, 1)
        XCTAssertTrue(try db.searchClips().isEmpty)
    }
    func testA34InvalidBase64AbortsBeforeChangingDatabase() async throws {
        let db = try database()
        let item = BackupClipItem(
            id: UUID(), contentHash: "bad", plainText: nil, customName: nil, primaryType: .image,
            sourceAppBundleId: nil, isFavorite: false, listId: nil, pasteCount: 0, manualSortIndex: 0,
            createdAt: Date(), updatedAt: Date(),
            payloads: [BackupPayloadItem(utiType: "public.png", base64Data: "@@invalid", byteSize: 7)])
        let archive = ConCopyArchive(lists: [ClipListRecord(name: "should roll back")], clips: [item])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("invalid.json")
        try encoder.encode(archive).write(to: url)
        do {
            try await ArchiveManager().importArchive(from: url, databaseManager: db)
            XCTFail("Expected validation failure")
        } catch { XCTAssertTrue(error is ArchiveError) }
        XCTAssertTrue(try db.fetchAllLists().isEmpty)
        XCTAssertTrue(try db.searchClips().isEmpty)
    }
}

extension AuditDataIntegrityTests {
    func testA22MaccyRejectsOversizedForeignBlobBeforeMaterializingIt() async throws {
        let url = directory.appendingPathComponent("oversized-maccy.sqlite")
        let source = try DatabaseQueue(path: url.path)
        try await source.write { database in
            try database.execute(
                sql:
                    "CREATE TABLE ZHISTORYITEM(Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZHISTORYITEMCONTENT(ZHISTORYITEM INTEGER,ZTYPE TEXT,ZVALUE BLOB); INSERT INTO ZHISTORYITEM VALUES(1)"
            )
            try database.execute(
                sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES(1,'public.png',zeroblob(?))",
                arguments: [ClipBatchImporter.maxBlobSizeBytes + 1])
        }
        XCTAssertThrowsError(try MaccyImporter(sourceURL: url).importClips(into: database(), progress: nil))
        XCTAssertTrue(try database().searchClips().isEmpty)
    }
    func testA22CopyEmRejectsOversizedForeignBlobBeforeMaterializingIt() async throws {
        let url = directory.appendingPathComponent("oversized-copyem.sqlite")
        let source = try DatabaseQueue(path: url.path)
        try await source.write { database in
            try database.execute(sql: "CREATE TABLE clips(id INTEGER PRIMARY KEY,content BLOB)")
            try database.execute(
                sql: "INSERT INTO clips VALUES(1,zeroblob(?))", arguments: [ClipBatchImporter.maxBlobSizeBytes + 1])
        }
        XCTAssertThrowsError(try CopyEmImporter(sourceURL: url).importClips(into: database(), progress: nil))
        XCTAssertTrue(try database().searchClips().isEmpty)
    }
    func testLegacyBackupWithoutSnippetsRemainsReadable() async throws {
        let db = try database()
        _ = try capture("legacy")
        let archive = directory.appendingPathComponent("legacy.json")
        try await ArchiveManager().exportArchive(to: archive, databaseManager: db)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        json["version"] = 1
        json.removeValue(forKey: "snippets")
        try JSONSerialization.data(withJSONObject: json).write(to: archive)
        let target = try DatabaseManager(
            inMemoryWithBlobDirectoryURL: directory.appendingPathComponent("legacy-restored"))
        try await ArchiveManager().importArchive(from: archive, databaseManager: target)
        XCTAssertEqual(try target.searchClips().first?.plainText, "legacy")
    }
}

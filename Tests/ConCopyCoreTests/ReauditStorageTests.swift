import AppKit
import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

private final class ArchiveReadGate: @unchecked Sendable {
    let ready = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let deletionStarted = DispatchSemaphore(value: 0)
    let deletionFinished = DispatchSemaphore(value: 0)
    func pause() { ready.signal(); _ = resume.wait(timeout: .now() + 5) }
    func waitForRead() { _ = ready.wait(timeout: .now() + 5) }
    func giveDeletionAChance() {
        _ = deletionStarted.wait(timeout: .now() + 5)
        _ = deletionFinished.wait(timeout: .now() + 0.1)
    }
}

@MainActor
final class ReauditStorageTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReauditStorage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func database(_ name: String = "db") throws -> DatabaseManager {
        try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent(name))
    }
    func testB08ValidBackupRepairsMissingBlob() async throws {
        let db = try database(), bytes = Data(repeating: 8, count: 5000)
        let clip = try db.ingestCapturedClip(CapturedClip(primaryType: .image, representations: ["public.png": bytes]))
        let backup = directory.appendingPathComponent("backup.json")
        try await ArchiveManager().exportArchive(to: backup, databaseManager: db)
        let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first)
        try db.blobStorage.deleteBlobIfExists(filename: XCTUnwrap(payload.blobFilename))
        try await ArchiveManager().importArchive(from: backup, databaseManager: db)
        let repaired = try XCTUnwrap(db.fetchPayloads(for: clip.id).first)
        XCTAssertEqual(try db.loadPayloadData(for: repaired), bytes)
        XCTAssertEqual(try db.searchClips().count, 1)
    }
    func testB09ConflictingSnippetVersionsAreRecoveredWithoutDuplicates() async throws {
        let db = try database(), id = UUID()
        try db.saveSnippet(SnippetRecord(id: id, shortcut: ";same", content: "original", title: "Title"))
        let backup = directory.appendingPathComponent("snippets.json")
        try await ArchiveManager().exportArchive(to: backup, databaseManager: db)
        try db.saveSnippet(SnippetRecord(id: id, shortcut: ";same", content: "local edit", title: "Title"))
        for _ in 0..<2 { try await ArchiveManager().importArchive(from: backup, databaseManager: db) }
        let snippets = try db.fetchSnippets()
        XCTAssertEqual(snippets.count, 2)
        XCTAssertEqual(Set(snippets.map(\.content)), ["original", "local edit"])
        XCTAssertEqual(snippets.first(where: { $0.id == id })?.content, "local edit")
        XCTAssertTrue(snippets.contains { $0.content == "original" && $0.shortcut.hasPrefix(";same~restored") })
        let other = try database("other")
        try other.saveSnippet(SnippetRecord(shortcut: ";same", content: "other ID"))
        try await ArchiveManager().importArchive(from: backup, databaseManager: other)
        XCTAssertEqual(try Set(other.fetchSnippets().map(\.content)), ["original", "other ID"])
    }
    func testB10BinaryAndTextIdentityDomainsAreSeparate() throws {
        let db = try database(), url = URL(fileURLWithPath: "/tmp/document.txt")
        let text = try db.ingestCapturedClip(CapturedClip(plainText: url.absoluteString))
        let file = try db.ingestCapturedClip(CapturedClip(plainText: "document.txt", primaryType: .file,
            representations: ["public.file-url": Data(url.absoluteString.utf8)]))
        XCTAssertNotEqual(text.id, file.id)
        XCTAssertEqual(try db.fetchClip(id: text.id)?.primaryType, .text)
        let asciiImage = "image bytes"
        let textImage = CapturedClip(plainText: asciiImage)
        let binaryImage = CapturedClip(primaryType: .image, representations: ["public.png": Data(asciiImage.utf8)])
        XCTAssertNotEqual(textImage.computeContentHash(), binaryImage.computeContentHash())
    }
    func testB11RecapturePublishesOnlyTheCurrentFormatting() throws {
        let db = try database(), rtf = Data("{\\rtf1\\ansi\\i same}".utf8)
        let first = try db.ingestCapturedClip(CapturedClip(plainText: "same", primaryType: .html,
            representations: ["public.html": Data("<b>same</b>".utf8)]))
        let second = try db.ingestCapturedClip(CapturedClip(plainText: "same", primaryType: .richText,
            representations: ["public.rtf": rtf]))
        XCTAssertEqual(first.id, second.id)
        let pasteboard = NSPasteboard.withUniqueName()
        try PasteInjector().preparePasteboard(for: second, payloads: db.fetchPayloads(for: second.id),
            databaseManager: db, pasteboard: pasteboard)
        XCTAssertNil(pasteboard.data(forType: .html))
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtf)
    }
    func testB15ConcurrentDeletionCannotInvalidateExportedBlob() async throws {
        let db = try DatabaseManager(diskDatabaseURL: directory.appendingPathComponent("archive.sqlite"),
            blobDirectoryURL: directory.appendingPathComponent("archive-blobs"))
        let bytes = Data(repeating: 9, count: 5000)
        let clip = try db.ingestCapturedClip(CapturedClip(primaryType: .image, representations: ["public.png": bytes]))
        let gate = ArchiveReadGate()
        let export = Task.detached { try db.makeArchive(willReadPayloads: { gate.pause() }) }
        await Task.detached { gate.waitForRead() }.value
        let deletion = Task.detached {
            gate.deletionStarted.signal()
            try db.deleteClip(clipId: clip.id)
            gate.deletionFinished.signal()
        }
        await Task.detached { gate.giveDeletionAChance() }.value
        gate.resume.signal()
        let archive = try await export.value
        try await deletion.value
        let payload = try XCTUnwrap(archive.clips.first?.payloads.first)
        XCTAssertEqual(Data(base64Encoded: payload.base64Data), bytes)
        XCTAssertNil(try db.fetchClip(id: clip.id))
    }
    private func rejectPayloadWrites(_ db: DatabaseManager) throws {
        try db.dbWriter.write { d in
            try d.execute(sql: "CREATE TRIGGER reject_payload BEFORE INSERT ON clip_payloads BEGIN SELECT RAISE(ABORT,'test write failure'); END")
        }
    }
    func testB16RollbackRemovesNewBlobsButKeepsSharedExistingBlobs() throws {
        let db = try database()
        try rejectPayloadWrites(db)
        XCTAssertThrowsError(try db.ingestCapturedClip(CapturedClip(primaryType: .image,
            representations: ["public.png": Data(repeating: 7, count: 5000)])))
        XCTAssertTrue(try db.searchClips().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: db.blobStorage.baseDirectoryURL.path).isEmpty)
        try db.dbWriter.write { try $0.execute(sql: "DROP TRIGGER reject_payload") }
        let shared = Data(repeating: 4, count: 5000)
        let original = try db.ingestCapturedClip(CapturedClip(plainText: "original", representations: ["public.html": shared]))
        try rejectPayloadWrites(db)
        XCTAssertThrowsError(try db.ingestCapturedClip(CapturedClip(plainText: "different", representations: ["public.html": shared])))
        XCTAssertThrowsError(try db.updateTextContent(clipId: original.id, newPlainText: String(repeating: "x", count: 5000)))
        let payload = try XCTUnwrap(db.fetchPayloads(for: original.id).first { $0.utiType == "public.html" })
        XCTAssertEqual(try db.loadPayloadData(for: payload), shared)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: db.blobStorage.baseDirectoryURL.path).count, 1)
    }
    private func makeLegacyDatabase(at path: URL, blobs: BlobStorageManager) throws -> (UUID, UUID, Data) {
        let q = try DatabaseQueue(path: path.path)
        try DatabaseManager.migrator(blobStorage: blobs).migrate(q, upTo: "v3_snippets_schema")
        let url = URL(fileURLWithPath: "/tmp/historic.txt")
        let file = ClipRecord(contentHash: CapturedClip(plainText: "historic.txt").computeContentHash(),
            plainText: "historic.txt", customName: "Important", primaryType: .file, isFavorite: true, pasteCount: 2)
        let duplicate = ClipRecord(contentHash: CapturedClip.hash(Data(url.absoluteString.utf8)),
            plainText: "historic.txt", primaryType: .file, pasteCount: 3)
        let bytes = Data(repeating: 1, count: 5000), blob = try blobs.storeBlob(data: bytes)
        let image = ClipRecord(contentHash: CapturedClip(plainText: "Image 2x2").computeContentHash(),
            plainText: "Image 2x2", primaryType: .image, isFavorite: true)
        try ClipRecord.$omitV9ColumnsDuringLegacyInsert.withValue(true) {
            try q.write { d in
                for record in [file, duplicate] {
                    try record.insert(d)
                    try ClipPayloadRecord(clipId: record.id, utiType: "public.file-url",
                        inlineData: Data(url.absoluteString.utf8), byteSize: url.absoluteString.utf8.count).insert(d)
                }
                try image.insert(d)
                try ClipPayloadRecord(clipId: image.id, utiType: "public.png", blobFilename: blob, byteSize: bytes.count).insert(d)
            }
        }
        return (file.id.uuidString < duplicate.id.uuidString ? file.id : duplicate.id, image.id, bytes)
    }
    func testB20LegacyFileAndImageHashesMigrateAndDeduplicateWithMetadata() throws {
        let path = directory.appendingPathComponent("v3.sqlite")
        let blobs = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent("legacy-blobs"))
        let (fileID, imageID, imageBytes) = try makeLegacyDatabase(at: path, blobs: blobs)
        let db = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: blobs.baseDirectoryURL)
        let url = URL(fileURLWithPath: "/tmp/historic.txt")
        let file = try db.ingestCapturedClip(CapturedClip(plainText: "historic.txt", primaryType: .file,
            representations: ["public.file-url": Data(url.absoluteString.utf8)]))
        let image = try db.ingestCapturedClip(CapturedClip(plainText: "new label", primaryType: .image,
            representations: ["public.png": imageBytes]))
        XCTAssertEqual(file.id, fileID)
        XCTAssertEqual(file.customName, "Important")
        XCTAssertTrue(file.isFavorite)
        XCTAssertEqual(file.pasteCount, 5)
        XCTAssertEqual(image.id, imageID)
        XCTAssertTrue(image.isFavorite)
        XCTAssertEqual(try db.searchClips().count, 2)
        let reopened = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: blobs.baseDirectoryURL)
        XCTAssertEqual(try reopened.searchClips().count, 2)
    }
    func testB08B20BackupRepairsLegacyIdentityWhoseBlobWasMissingDuringUpgrade() async throws {
        let path = directory.appendingPathComponent("damaged-v3.sqlite")
        let blobs = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent("damaged-blobs"))
        let (_, imageID, bytes) = try makeLegacyDatabase(at: path, blobs: blobs)
        try blobs.deleteBlobIfExists(filename: CapturedClip.hash(bytes) + ".blob")
        let db = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: blobs.baseDirectoryURL)
        let old = try XCTUnwrap(db.fetchClip(id: imageID))
        let item = BackupClipItem(id: old.id, contentHash: old.contentHash, plainText: old.plainText,
            customName: old.customName, primaryType: old.primaryType, sourceAppBundleId: old.sourceAppBundleId,
            isFavorite: old.isFavorite, listId: nil, pasteCount: old.pasteCount, manualSortIndex: old.manualSortIndex,
            createdAt: old.createdAt, updatedAt: old.updatedAt,
            payloads: [BackupPayloadItem(utiType: "public.png", base64Data: bytes.base64EncodedString(), byteSize: bytes.count)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let backup = directory.appendingPathComponent("old-backup.json")
        try encoder.encode(ConCopyArchive(lists: [], clips: [item])).write(to: backup)
        try await ArchiveManager().importArchive(from: backup, databaseManager: db)
        let recaptured = try db.ingestCapturedClip(CapturedClip(primaryType: .image, representations: ["public.png": bytes]))
        XCTAssertEqual(recaptured.id, imageID)
        XCTAssertEqual(try db.searchClips().count, 2)
    }
}

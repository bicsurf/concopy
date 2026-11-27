import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

final class ThirdAuditStorageTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = directory.appendingPathComponent("ThirdStorage-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func database(_ name: String = "db") throws -> DatabaseManager {
        try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent(name))
    }
    private func write(_ archive: ConCopyArchive, name: String = "backup") throws -> URL {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent(name + ".json")
        try encoder.encode(archive).write(to: url)
        return url
    }
    func testC03LegacyAliasRestoreDoesNotCountTheSameUsageTwice() async throws {
        let db = try database(), original = UUID()
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "same"))
        try await db.dbWriter.write { sql in
            try sql.execute(sql: "INSERT INTO sync_aliases VALUES (?,?)", arguments: [original.uuidString.lowercased(), clip.id.uuidString.lowercased()])
            try sql.execute(sql: "INSERT INTO sync_usage VALUES (?,?,5)", arguments: [clip.id.uuidString.lowercased(), "legacy:" + original.uuidString.lowercased()])
            try sql.execute(sql: "UPDATE clips SET pasteCount=5 WHERE id=?", arguments: [clip.id.uuidString.lowercased()])
        }
        let item = BackupClipItem(id: original, contentHash: clip.contentHash, plainText: "same", customName: nil,
            primaryType: .text, sourceAppBundleId: nil, isFavorite: false, listId: nil, pasteCount: 5,
            manualSortIndex: 0, createdAt: clip.createdAt, updatedAt: clip.updatedAt, payloads: [])
        let backup = try write(ConCopyArchive(version: 1, lists: [], clips: [item]))
        for _ in 0..<3 { try await ArchiveManager().importArchive(from: backup, databaseManager: db) }
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.pasteCount, 5)
        let components = try await db.dbWriter.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_usage") }
        XCTAssertEqual(components, 1)
    }
    func testC04LegitimateRestoredSuffixesAreNotMistakenForDuplicates() async throws {
        let snippets = [SnippetRecord(shortcut: ";hello~restored", content: "same", title: "Title"),
            SnippetRecord(shortcut: ";hello", content: "same", title: "Title")]
        for reverse in [false, true] {
            let db = try database("order-\(reverse)")
            let url = try write(ConCopyArchive(lists: [], clips: [], snippets: reverse ? Array(snippets.reversed()) : snippets))
            for _ in 0..<2 { try await ArchiveManager().importArchive(from: url, databaseManager: db) }
            XCTAssertEqual(try Set(db.fetchSnippets().map(\.id)), Set(snippets.map(\.id)))
        }
    }
    func testC04SnippetProvenanceSurvivesBackupRoundTripAndSync() async throws {
        let source = SnippetRecord(shortcut: ";hello", content: "old", title: "Title")
        let original = try write(ConCopyArchive(lists: [], clips: [], snippets: [source]), name: "original")
        let a = try database("a")
        var edited = source; edited.content = "edited"
        try a.saveSnippet(edited)
        try await ArchiveManager().importArchive(from: original, databaseManager: a)
        let restoredIDs = try Set(a.fetchSnippets().map(\.id))
        XCTAssertEqual(restoredIDs.count, 2)
        let roundTrip = directory.appendingPathComponent("round-trip.json")
        try await ArchiveManager().exportArchive(to: roundTrip, databaseManager: a)
        let b = try database("b")
        try await ArchiveManager().importArchive(from: roundTrip, databaseManager: b)
        try await ArchiveManager().importArchive(from: original, databaseManager: b)
        XCTAssertEqual(try Set(b.fetchSnippets().map(\.id)), restoredIDs)
        let cloud = directory.appendingPathComponent("cloud")
        let wa = CloudDriveSyncWorker(databaseManager: a, customSyncDirectoryURL: cloud, deviceId: "a")
        let wb = CloudDriveSyncWorker(databaseManager: b, customSyncDirectoryURL: cloud, deviceId: "b")
        let first = await wa.performSync(); XCTAssertEqual(first.status, .idle)
        try b.saveSnippet(SnippetRecord(shortcut: ";other", content: "unrelated"))
        let second = await wb.performSync(); XCTAssertEqual(second.status, .idle)
        let third = await wa.performSync(); XCTAssertEqual(third.status, .idle)
        try await ArchiveManager().importArchive(from: original, databaseManager: a)
        XCTAssertEqual(try a.fetchSnippets().count, 3)
        XCTAssertEqual(try Set(a.fetchSnippets().filter { $0.content != "unrelated" }.map(\.id)), restoredIDs)
    }
    func testC05BackupRepairsTruncatedAndSameLengthCorruptedBlobs() async throws {
        for truncated in [false, true] {
            let db = try database("corrupt-\(truncated)"), bytes = Data(repeating: 8, count: 5000)
            let clip = try db.ingestCapturedClip(CapturedClip(primaryType: .image, representations: ["public.png": bytes]))
            let backup = directory.appendingPathComponent("corrupt-\(truncated).json")
            try await ArchiveManager().exportArchive(to: backup, databaseManager: db)
            let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first)
            let name = try XCTUnwrap(payload.blobFilename)
            try Data(repeating: 0, count: truncated ? 33 : bytes.count).write(to: db.blobStorage.baseDirectoryURL.appendingPathComponent(name))
            XCTAssertThrowsError(try db.loadPayloadData(for: payload))
            try await ArchiveManager().importArchive(from: backup, databaseManager: db)
            XCTAssertEqual(try db.loadPayloadData(for: payload), bytes)
            XCTAssertEqual(try db.searchClips().count, 1)
        }
    }
    func testC05StoreRepairsExistingCorruptContentAddressedFile() throws {
        let storage = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent("blobs"))
        let bytes = Data(repeating: 7, count: 5000), filename = try storage.storeBlob(data: Data(repeating: 7, count: 5000))
        try Data(repeating: 3, count: bytes.count).write(to: storage.baseDirectoryURL.appendingPathComponent(filename))
        XCTAssertEqual(try storage.storeBlob(data: bytes), filename)
        XCTAssertEqual(try storage.loadBlob(filename: filename), bytes)
    }
    func testC06IdentityMigrationCollectsOnlyUnreferencedBlobsAfterCommit() throws {
        let path = directory.appendingPathComponent("legacy.sqlite")
        let storage = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent("legacy-blobs"))
        let png = Data(repeating: 1, count: 5000), tiff = Data(repeating: 2, count: 6000)
        let pngName = try storage.storeBlob(data: png), tiffName = try storage.storeBlob(data: tiff)
        let queue = try DatabaseQueue(path: path.path)
        try DatabaseManager.migrator(blobStorage: storage).migrate(queue, upTo: "v5_independent_usage_counters")
        try ClipRecord.$omitV9ColumnsDuringLegacyInsert.withValue(true) {
            try queue.write { sql in
                for index in 0..<2 {
                    let clip = ClipRecord(contentHash: "legacy-\(index)", primaryType: .image,
                        updatedAt: Date(timeIntervalSince1970: Double(index + 1)))
                    try clip.insert(sql)
                    try ClipPayloadRecord(clipId: clip.id, utiType: "public.png", blobFilename: pngName, byteSize: png.count).insert(sql)
                    if index == 0 { try ClipPayloadRecord(clipId: clip.id, utiType: "public.tiff", blobFilename: tiffName, byteSize: tiff.count).insert(sql) }
                }
            }
        }
        // A later SQL failure rolls the migration back; its old blobs must still exist.
        XCTAssertThrowsError(try queue.write { sql in
            try DatabaseManager.migrateBinaryIdentities(in: sql, blobStorage: storage)
            throw CocoaError(.fileWriteUnknown)
        })
        XCTAssertEqual(try storage.loadBlob(filename: tiffName), tiff)
        let db = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: storage.baseDirectoryURL)
        XCTAssertEqual(try db.searchClips().count, 1)
        XCTAssertEqual(try storage.loadBlob(filename: pngName), png)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.baseDirectoryURL.appendingPathComponent(tiffName).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.baseDirectoryURL.path), [pngName])
    }
    func testC06UpgradeAlsoCollectsOrphansFromAlreadyAppliedV6() throws {
        let path = directory.appendingPathComponent("already-v6.sqlite")
        let storage = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent("already-v6-blobs"))
        let queue = try DatabaseQueue(path: path.path)
        try DatabaseManager.migrator(blobStorage: storage).migrate(queue, upTo: "v6_binary_content_identity")
        let orphan = try storage.storeBlob(data: Data(repeating: 4, count: 5000))
        _ = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: storage.baseDirectoryURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.baseDirectoryURL.appendingPathComponent(orphan).path))
    }
}

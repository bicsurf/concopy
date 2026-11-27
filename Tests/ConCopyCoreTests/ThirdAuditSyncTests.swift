import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

final class ThirdAuditSyncTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func id(_ n: Int) throws -> UUID {
        try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)))
    }
    private func database(_ name: String) throws -> DatabaseManager {
        try DatabaseManager(diskDatabaseURL: directory.appendingPathComponent(name + ".sqlite"),
            blobDirectoryURL: directory.appendingPathComponent(name + "-blobs"))
    }
    private func worker(_ db: DatabaseManager) -> CloudDriveSyncWorker {
        CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: directory.appendingPathComponent("cloud"), deviceId: db.blobStorage.baseDirectoryURL.lastPathComponent)
    }
    private func sync(_ worker: CloudDriveSyncWorker) async {
        let result = await worker.performSync()
        XCTAssertEqual(result.status, .idle)
    }
    private func makeLegacy(_ name: String, record: ClipRecord, payloads: [String: Data]) throws {
        let blobs = BlobStorageManager(baseDirectoryURL: directory.appendingPathComponent(name + "-blobs"))
        let queue = try DatabaseQueue(path: directory.appendingPathComponent(name + ".sqlite").path)
        try DatabaseManager.migrator(blobStorage: blobs).migrate(queue, upTo: "v4_sync_change_journal")
        try ClipRecord.$omitV9ColumnsDuringLegacyInsert.withValue(true) {
            try queue.write { db in
                try record.insert(db)
                for (uti, data) in payloads {
                    try ClipPayloadRecord(clipId: record.id, utiType: uti, inlineData: data, byteSize: data.count).insert(db)
                }
            }
        }
    }
    func testC01UpgradeDoesNotSupersedeRemoteRenameOrDeletion() async throws {
        for deletion in [false, true] {
            let suffix = deletion ? "delete" : "rename"
            let bytes = Data(URL(fileURLWithPath: "/tmp/shared.txt").absoluteString.utf8)
            let clip = ClipRecord(contentHash: CapturedClip.hash(bytes), plainText: "shared.txt",
                customName: "old", primaryType: .file, updatedAt: Date(timeIntervalSince1970: 1000))
            try makeLegacy("a-" + suffix, record: clip, payloads: ["public.file-url": bytes])
            try makeLegacy("b-" + suffix, record: clip, payloads: ["public.file-url": bytes])
            let b = try database("b-" + suffix), wb = worker(b)
            if deletion { try b.deleteClip(clipId: clip.id) }
            else { try b.updateCustomName(clipId: clip.id, name: "new on B") }
            await sync(wb)
            try await Task.sleep(nanoseconds: 20_000_000)
            let a = try database("a-" + suffix), wa = worker(a)
            await sync(wa); await sync(wb)
            if deletion {
                XCTAssertNil(try a.fetchClip(id: clip.id))
                XCTAssertNil(try b.fetchClip(id: clip.id))
            } else {
                XCTAssertEqual(try a.fetchClip(id: clip.id)?.customName, "new on B")
                XCTAssertEqual(try b.fetchClip(id: clip.id)?.customName, "new on B")
            }
        }
    }
    func testC02OfflineAliasRecapturePreservesMetadataAndExplicitRemoval() async throws {
        let a = try database("a"), b = try database("b")
        let first = ClipRecord(id: try id(1), contentHash: CapturedClip(plainText: "same").computeContentHash(), plainText: "same", primaryType: .text)
        let second = ClipRecord(id: try id(2), contentHash: first.contentHash, plainText: "same", primaryType: .text)
        for (db, clip) in [(a, first), (b, second)] {
            try await db.dbWriter.write { sql in
                try clip.insert(sql)
                try db.replacePayloads(clipId: clip.id, representations: ["public.utf8-plain-text": Data("same".utf8)], db: sql)
            }
        }
        let wa = worker(a), wb = worker(b)
        await sync(wb)
        _ = try a.toggleFavorite(clipId: first.id)
        try a.updateCustomName(clipId: first.id, name: "Important")
        let list = try a.createList(name: "Work")
        _ = try a.assignClip(clipId: first.id, toListId: list.id)
        await sync(wa)
        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try b.ingestCapturedClip(CapturedClip(plainText: "same"))
        await sync(wb); await sync(wa)
        for db in [a,b] {
            let clip = try XCTUnwrap(db.fetchClip(id: first.id))
            XCTAssertTrue(clip.isFavorite)
            XCTAssertEqual(clip.customName, "Important")
            XCTAssertEqual(clip.listId, list.id)
        }
        _ = try b.toggleFavorite(clipId: first.id)
        try b.updateCustomName(clipId: first.id, name: nil)
        _ = try b.assignClip(clipId: first.id, toListId: nil)
        await sync(wb)
        _ = try a.ingestCapturedClip(CapturedClip(plainText: "same"))
        await sync(wa); await sync(wb)
        XCTAssertEqual(try a.fetchClip(id: first.id)?.isFavorite, false)
        XCTAssertNil(try a.fetchClip(id: first.id)?.customName)
        XCTAssertNil(try a.fetchClip(id: first.id)?.listId)
    }
    func testC02IndependentMetadataFieldsAndContentConvergeAfterSerialization() throws {
        let date = Date(timeIntervalSince1970: 1000.123456)
        let list = ClipListRecord(name: "Work")
        let clip = ClipRecord(contentHash: CapturedClip(plainText: "same").computeContentHash(),
            plainText: "same", customName: "retained", primaryType: .text, isFavorite: true,
            listId: list.id, manualSortIndex: 9, createdAt: date, updatedAt: date)
        var recaptured = clip
        recaptured.customName = nil; recaptured.isFavorite = false
        recaptured.listId = nil; recaptured.manualSortIndex = 0
        recaptured.primaryType = .html; recaptured.updatedAt = date.addingTimeInterval(3)
        let key = clip.id.uuidString.lowercased(), revision = "clip:" + key
        let rich = Data("<b>same</b>".utf8)
        let metadata = CloudSyncState(clips: [clip], lists: [list], revisions: [revision: date],
            metadataRevisions: [key: ["isFavorite": date.addingTimeInterval(1), "customName": date.addingTimeInterval(1),
                "listId": date.addingTimeInterval(1), "manualSortIndex": date.addingTimeInterval(1)]])
        let content = CloudSyncState(clips: [recaptured], lists: [list],
            payloads: [key: [BackupPayloadItem(utiType: "public.html", base64Data: rich.base64EncodedString(), byteSize: rich.count)]],
            revisions: [revision: date.addingTimeInterval(3)])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CloudSyncState.self, from: encoder.encode(metadata))
        XCTAssertEqual(decoded.metadataRevisions, metadata.metadataRevisions)
        let ab = try CloudDriveSyncWorker.merge(decoded, content)
        let ba = try CloudDriveSyncWorker.merge(content, decoded)
        XCTAssertEqual(try encoder.encode(ab), try encoder.encode(ba))
        let merged = try XCTUnwrap(ab.clips.first)
        XCTAssertTrue(merged.isFavorite); XCTAssertEqual(merged.customName, "retained")
        XCTAssertEqual(merged.listId, list.id); XCTAssertEqual(merged.manualSortIndex, 9)
        XCTAssertEqual(merged.primaryType, .html)
        XCTAssertEqual(ab.payloads[key]?.first?.base64Data, rich.base64EncodedString())
        XCTAssertEqual(try encoder.encode(CloudDriveSyncWorker.merge(ab, content)), try encoder.encode(ab))
        // Explicit clears carry their own clocks and must beat old non-default metadata.
        var cleared = content
        cleared.metadataRevisions = [key: ["isFavorite": date.addingTimeInterval(4), "customName": date.addingTimeInterval(4),
            "listId": date.addingTimeInterval(4), "manualSortIndex": date.addingTimeInterval(4)]]
        let final = try XCTUnwrap(CloudDriveSyncWorker.merge(ab, cleared).clips.first)
        XCTAssertFalse(final.isFavorite); XCTAssertNil(final.customName); XCTAssertNil(final.listId)
        XCTAssertEqual(final.manualSortIndex, 0)
    }
}

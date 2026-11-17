import Foundation
import XCTest

@testable import ConCopyCore

final class AuditSyncTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopySyncAudit_\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func database(_ name: String) throws -> DatabaseManager {
        try DatabaseManager(
            diskDatabaseURL: directory.appendingPathComponent(name + ".sqlite"),
            blobDirectoryURL: directory.appendingPathComponent(name))
    }
    private func worker(_ db: DatabaseManager) -> CloudDriveSyncWorker {
        CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: directory.appendingPathComponent("cloud"))
    }
    private func sync(_ worker: CloudDriveSyncWorker) async {
        let result = await worker.performSync()
        XCTAssertEqual(result.status, .idle)
    }
    func testA01DisabledAndStoppedCoordinatorDoesNotWrite() async throws {
        let db = try database("off")
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "private"))
        let coordinator = CloudKitSyncCoordinator(
            databaseManager: db, customSyncDirectoryURL: directory.appendingPathComponent("cloud"),
            pollingInterval: 0.05, debounceInterval: 0.01)
        coordinator.queueUpload(for: clip)
        await coordinator.performSync()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud").path))
        coordinator.startIfPossible()
        coordinator.stop()
        coordinator.queueUpload(for: clip)
        await coordinator.performSync()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("cloud/sync-state-v2.json").path))
    }
    func testA06A07StableIdentityAndPersistentDeletionAcrossRestart() async throws {
        let a = try database("a")
        let b = try database("b")
        let wa = worker(a)
        let wb = worker(b)
        let original = try a.ingestCapturedClip(CapturedClip(plainText: "shared"))
        await sync(wa)
        await sync(wb)
        XCTAssertEqual(try b.searchClips().first?.id, original.id)
        try a.deleteClip(clipId: original.id)
        // Recreate both worker and database to prove the UI/storage deletion survives restarts.
        let reopened = try database("a")
        await sync(worker(reopened))
        await sync(wb)
        await sync(wa)
        XCTAssertTrue(try b.searchClips().isEmpty)
        XCTAssertTrue(try a.searchClips().isEmpty)
    }
    func testA08A18A20SyncPayloadsMetadataListsAndSnippets() async throws {
        let a = try database("a")
        let b = try database("b")
        let wa = worker(a)
        let wb = worker(b)
        let list = try a.createList(name: "Work")
        let image = try a.ingestCapturedClip(
            CapturedClip(primaryType: .image, representations: ["public.png": Data(repeating: 8, count: 6000)]))
        _ = try a.assignClip(clipId: image.id, toListId: list.id)
        let snippet = SnippetRecord(shortcut: ";sig", content: "signature")
        try a.saveSnippet(snippet)
        await sync(wa)
        await sync(wb)
        XCTAssertEqual(try b.fetchClip(id: image.id)?.listId, list.id)
        let payload = try XCTUnwrap(b.fetchPayloads(for: image.id).first { $0.utiType == "public.png" })
        XCTAssertEqual(try b.loadPayloadData(for: payload), Data(repeating: 8, count: 6000))
        XCTAssertEqual(try b.fetchAllLists().first?.id, list.id)
        XCTAssertEqual(try b.fetchSnippets().first?.id, snippet.id)
        _ = try a.toggleFavorite(clipId: image.id)
        try a.updateCustomName(clipId: image.id, name: "renamed")
        try a.renameList(listId: list.id, newName: "Renamed list")
        await sync(wa)
        await sync(wb)
        XCTAssertTrue(try XCTUnwrap(b.fetchClip(id: image.id)).isFavorite)
        XCTAssertEqual(try b.fetchClip(id: image.id)?.customName, "renamed")
        XCTAssertEqual(try b.fetchAllLists().first?.name, "Renamed list")
        try a.deleteSnippet(id: snippet.id)
        try a.deleteList(listId: list.id)
        await sync(wa)
        await sync(wb)
        XCTAssertTrue(try b.fetchSnippets().isEmpty)
        XCTAssertTrue(try b.fetchAllLists().isEmpty)
        XCTAssertNil(try b.fetchClip(id: image.id)?.listId)
        try a.deleteClip(clipId: image.id)
        await sync(wa)
        await sync(wb)
        XCTAssertNil(try b.fetchClip(id: image.id))
        if let filename = payload.blobFilename {
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: b.blobStorage.baseDirectoryURL.appendingPathComponent(filename).path))
        }
    }
    func testA06IndependentDuplicatesConvergeAndAliasDeletionPropagates() async throws {
        let a = try database("a")
        let b = try database("b")
        let wa = worker(a)
        let wb = worker(b)
        _ = try a.ingestCapturedClip(CapturedClip(plainText: "duplicate"))
        _ = try b.ingestCapturedClip(CapturedClip(plainText: "duplicate"))
        await sync(wa)
        await sync(wb)
        await sync(wa)
        let first = try XCTUnwrap(a.searchClips().first)
        let second = try XCTUnwrap(b.searchClips().first)
        XCTAssertEqual(first.id, second.id)
        try b.deleteClip(clipId: second.id)
        await sync(wb)
        await sync(wa)
        XCTAssertTrue(try a.searchClips().isEmpty)
    }
    func testA12CorruptStateIsPreservedAndReported() async throws {
        let db = try database("a")
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let file = cloud.appendingPathComponent("sync-state-v1.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: file)
        let result = await worker(db).performSync()
        XCTAssertEqual(result.status, .error)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }
    func testA19IdleReceiverAndLocalMutationsAreObserved() async throws {
        let a = try database("a")
        let b = try database("b")
        let wa = worker(a)
        let coordinator = CloudKitSyncCoordinator(
            databaseManager: b, customSyncDirectoryURL: directory.appendingPathComponent("cloud"),
            pollingInterval: 0.05, debounceInterval: 0.02)
        coordinator.startIfPossible()
        defer { coordinator.stop() }
        let clip = try a.ingestCapturedClip(CapturedClip(plainText: "remote"))
        await sync(wa)
        for _ in 0..<100 {
            if try b.fetchClip(id: clip.id) != nil { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(try b.fetchClip(id: clip.id))
        _ = try b.toggleFavorite(clipId: clip.id)
        for _ in 0..<100 {
            await sync(wa)
            if try a.fetchClip(id: clip.id)?.isFavorite == true { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(try a.fetchClip(id: clip.id)?.isFavorite, true)
    }
    func testA37MoreThan1000ClipsAreSynchronized() async throws {
        let a = try database("a")
        let b = try database("b")
        for i in 0..<1005 { _ = try a.ingestCapturedClip(CapturedClip(plainText: "clip \(i)")) }
        await sync(worker(a))
        await sync(worker(b))
        XCTAssertEqual(try b.searchClips(limit: 2000).count, 1005)
    }
}

extension AuditSyncTests {
    func testA06OfflineAliasCannotResurrectCanonicalDeletion() throws {
        let old = ClipRecord(contentHash: "same", plainText: "same", primaryType: .text)
        let canonicalID = UUID()
        let deletedAt = Date().addingTimeInterval(10)
        let remote = CloudSyncState(
            tombstones: [canonicalID.uuidString.lowercased(): deletedAt],
            aliases: [old.id.uuidString.lowercased(): canonicalID.uuidString.lowercased()])
        let merged = try CloudDriveSyncWorker.merge(CloudSyncState(clips: [old]), remote)
        XCTAssertTrue(merged.clips.isEmpty)
    }
    func testLegacySyncStateAndIdleSyncDoNotRewriteFile() async throws {
        let db = try database("legacy")
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let clip = ClipRecord(
            contentHash: CapturedClip(plainText: "legacy").computeContentHash(), plainText: "legacy", primaryType: .text
        )
        let file = cloud.appendingPathComponent("sync-state-v1.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let v1: [String: Any] = [
            "version": 1, "lastModifiedDeviceId": "old", "updatedAt": "2026-01-01T00:00:00Z",
            "clips": try JSONSerialization.jsonObject(with: encoder.encode([clip])), "tombstones": [:],
        ]
        try JSONSerialization.data(withJSONObject: v1).write(to: file)
        let worker = worker(db)
        await sync(worker)
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.plainText, "legacy")
        let newFile = await worker.syncFileURL
        let bytes = try Data(contentsOf: newFile)
        let modified = try newFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        await sync(worker)
        XCTAssertEqual(try Data(contentsOf: newFile), bytes)
        XCTAssertEqual(
            try newFile.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified)
        XCTAssertEqual(
            try (JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])?["version"] as? Int, 1)
    }
}

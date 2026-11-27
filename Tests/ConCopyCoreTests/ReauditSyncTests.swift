import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

private final class SyncWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let ready = DispatchSemaphore(value: 0)
    func authorize() -> Bool {
        let call = lock.withLock { calls += 1; return calls }
        if call == 4 { ready.signal(); Thread.sleep(forTimeInterval: 0.12) }
        return true
    }
    func wait() { _ = ready.wait(timeout: .now() + 5) }
}

final class ReauditSyncTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReauditSync-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
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
    private func cloudState(at url: URL) throws -> CloudSyncState {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudSyncState.self, from: Data(contentsOf: url))
    }
    func testB01UsageDoesNotUndoRemoteEditAndOfflineCountersConverge() async throws {
        let a = try database("a"), b = try database("b"), wa = worker(a), wb = worker(b)
        let clip = try a.ingestCapturedClip(CapturedClip(plainText: "original"))
        await sync(wa); await sync(wb)
        try a.updateTextContent(clipId: clip.id, newPlainText: "edited")
        _ = try a.recordPasteUsage(clipId: clip.id)
        _ = try b.recordPasteUsage(clipId: clip.id)
        _ = try b.recordPasteUsage(clipId: clip.id)
        await sync(wa); await sync(wb); await sync(wa); await sync(wb)
        for db in [a,b] {
            XCTAssertEqual(try db.fetchClip(id: clip.id)?.plainText, "edited")
            XCTAssertEqual(try db.fetchClip(id: clip.id)?.pasteCount, 3)
            let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first)
            XCTAssertEqual(try db.loadPayloadData(for: payload), Data("edited".utf8))
        }
    }
    func testB01BackupRoundTripDoesNotDoubleUsageWhenRejoiningSync() async throws {
        let a = try database("a"), wa = worker(a)
        let clip = try a.ingestCapturedClip(CapturedClip(plainText: "backup counter"))
        _ = try a.recordPasteUsage(clipId: clip.id)
        _ = try a.recordPasteUsage(clipId: clip.id)
        await sync(wa)
        let backup = directory.appendingPathComponent("counter.json")
        try await ArchiveManager().exportArchive(to: backup, databaseManager: a)
        let restored = try database("restored"), wr = worker(restored)
        try await ArchiveManager().importArchive(from: backup, databaseManager: restored)
        await sync(wr); await sync(wa)
        XCTAssertEqual(try a.fetchClip(id: clip.id)?.pasteCount, 2)
        _ = try restored.recordPasteUsage(clipId: clip.id)
        await sync(wr); await sync(wa)
        XCTAssertEqual(try a.fetchClip(id: clip.id)?.pasteCount, 3)
    }
    func testB02MutationQueuedDuringPublicationIsSentOnNextCycle() async throws {
        let db = try database("race"), w = worker(db), gate = SyncWriteGate()
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "initial"))
        let mutation = Task.detached {
            gate.wait()
            return try db.ingestCapturedClip(CapturedClip(plainText: "during publication"))
        }
        let publishedURL = await w.myDeviceFileURL
        let result = await w.performSync(isAuthorized: { gate.authorize() })
        XCTAssertEqual(result.status, .idle)
        let clip = try await mutation.value
        XCTAssertFalse(try cloudState(at: publishedURL).clips.contains { $0.id == clip.id })
        await sync(w)
        XCTAssertTrue(try cloudState(at: publishedURL).clips.contains { $0.id == clip.id })
    }
    func testB03IndependentDuplicatePreservesExplicitMetadata() async throws {
        let a = try database("a"), b = try database("b"), wa = worker(a), wb = worker(b)
        let clip = try a.ingestCapturedClip(CapturedClip(plainText: "same"))
        let list = try a.createList(name: "Important")
        _ = try a.toggleFavorite(clipId: clip.id)
        _ = try a.assignClip(clipId: clip.id, toListId: list.id)
        try a.updateCustomName(clipId: clip.id, name: "Keep this")
        try await Task.sleep(nanoseconds: 10_000_000)
        _ = try b.ingestCapturedClip(CapturedClip(plainText: "same"))
        await sync(wa); await sync(wb); await sync(wa)
        for db in [a,b] {
            let merged = try XCTUnwrap(db.searchClips().first)
            XCTAssertTrue(merged.isFavorite)
            XCTAssertEqual(merged.customName, "Keep this")
            XCTAssertEqual(merged.listId, list.id)
            XCTAssertEqual(try db.searchClips().count, 1)
        }
    }

    func testB05OfflineAliasEditReachesItsIdentityBeforeContentDeduplication() throws {
        let date = Date(timeIntervalSince1970: 1000)
        let ids = try (1...3).map { try XCTUnwrap(UUID(uuidString: String(format:"00000000-0000-0000-0000-%012d",$0))) }
        let a = ClipRecord(id: ids[0], contentHash: "alpha", plainText: "alpha", primaryType: .text, updatedAt: date)
        let b = ClipRecord(id: ids[1], contentHash: "beta", plainText: "beta", primaryType: .text, updatedAt: date.addingTimeInterval(1))
        let offline = ClipRecord(id: ids[2], contentHash: "beta", plainText: "beta", primaryType: .text, updatedAt: date.addingTimeInterval(2))
        let merged = try CloudDriveSyncWorker.merge(CloudSyncState(clips:[a,b]),
            CloudSyncState(clips:[offline], aliases:[ids[2].uuidString.lowercased():ids[0].uuidString.lowercased()]))
        XCTAssertEqual(merged.clips.count, 1)
        XCTAssertEqual(merged.clips.first?.id, ids[0])
        XCTAssertEqual(merged.clips.first?.plainText, "beta")
        XCTAssertEqual(merged.aliases[ids[2].uuidString.lowercased()], ids[0].uuidString.lowercased())
    }
    func testB06LegacyDownloadCompletesBeforeDeviceSnapshotIsCreated() async throws {
        let db = try database("legacy"), cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let placeholder = cloud.appendingPathComponent(".sync-state-v1.json.icloud")
        try Data().write(to: placeholder)
        let w = CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: cloud, startDownload: { _ in })
        let waiting = await w.performSync()
        XCTAssertEqual(waiting.status, .syncing)
        let publishedURL = await w.myDeviceFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: publishedURL.path))
        let clip = ClipRecord(contentHash:"legacy",plainText:"legacy",primaryType:.text)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CloudSyncState(version:1,clips:[clip])).write(to:cloud.appendingPathComponent("sync-state-v1.json"))
        try FileManager.default.removeItem(at: placeholder)
        await sync(w)
        XCTAssertEqual(try db.fetchClip(id:clip.id)?.plainText,"legacy")
    }
    func testB07EqualRevisionPayloadConflictsAreCommutativeAndIdempotent() throws {
        let date = Date(timeIntervalSince1970:1000)
        let clip = ClipRecord(contentHash:"same",plainText:"same",primaryType:.richText,createdAt:date,updatedAt:date)
        let key = clip.id.uuidString.lowercased()
        func state(_ data: String) -> CloudSyncState {
            CloudSyncState(clips:[clip],payloads:[key:[BackupPayloadItem(utiType:"public.rtf",base64Data:Data(data.utf8).base64EncodedString(),byteSize:data.utf8.count)]],revisions:["clip:"+key:date])
        }
        let ab = try CloudDriveSyncWorker.merge(state("format A"),state("format B"))
        let ba = try CloudDriveSyncWorker.merge(state("format B"),state("format A"))
        XCTAssertEqual(ab.payloads[key]?.first?.base64Data,ba.payloads[key]?.first?.base64Data)
        let again = try CloudDriveSyncWorker.merge(ab,ba)
        XCTAssertEqual(again.payloads[key]?.first?.base64Data,ab.payloads[key]?.first?.base64Data)
    }
    func testB13GeneratedShortcutDoesNotCollideWithAnExistingSuffix() async throws {
        let ids = try (1...3).map { try XCTUnwrap(UUID(uuidString:String(format:"00000000-0000-0000-0000-%012d",$0))) }
        let snippets = [SnippetRecord(id:ids[0],shortcut:";hello",content:"first"),
            SnippetRecord(id:ids[1],shortcut:";hello",content:"second"),
            SnippetRecord(id:ids[2],shortcut:";hello~"+ids[1].uuidString.lowercased(),content:"third")]
        let cloud = directory.appendingPathComponent("cloud")
        try FileManager.default.createDirectory(at:cloud,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CloudSyncState(snippets:snippets)).write(to:cloud.appendingPathComponent("sync-state-v2.json"))
        let db = try database("snippets")
        await sync(worker(db))
        XCTAssertEqual(try db.fetchSnippets().count,3)
        XCTAssertEqual(try Set(db.fetchSnippets().map(\.shortcut)).count,3)
    }
    func testB16FailedSyncApplyRemovesOnlyUnreferencedNewBlobs() async throws {
        let source = try database("source"), destination = try database("destination")
        let old = try destination.ingestCapturedClip(CapturedClip(plainText: "local",
            representations: ["public.html": Data(repeating: 3, count: 5000)]))
        _ = try source.ingestCapturedClip(CapturedClip(primaryType: .image,
            representations: ["public.png": Data(repeating: 7, count: 5000)]))
        await sync(worker(source))
        try await destination.dbWriter.write {
            try $0.execute(sql: "CREATE TRIGGER reject_sync_payload BEFORE INSERT ON clip_payloads BEGIN SELECT RAISE(ABORT,'test failure'); END")
        }
        let failed = await worker(destination).performSync()
        XCTAssertEqual(failed.status, .error)
        XCTAssertEqual(try destination.searchClips().count, 1)
        let payload = try XCTUnwrap(destination.fetchPayloads(for: old.id).first { $0.utiType == "public.html" })
        XCTAssertEqual(try destination.loadPayloadData(for: payload), Data(repeating: 3, count: 5000))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.blobStorage.baseDirectoryURL.path).count, 1)
    }
}

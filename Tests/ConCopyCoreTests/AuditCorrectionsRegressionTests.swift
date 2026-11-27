import XCTest
import GRDB
@testable import ConCopyCore

private final class AuditLockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: Value) { lock.lock(); defer { lock.unlock() }; self.value = value }
}

final class AuditCorrectionsRegressionTests: XCTestCase {
    private let secret = "api_key=sk-1234567890abcdef1234567890abcdef"

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopyAudit-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func database(_ root: URL, _ name: String) throws -> DatabaseManager {
        let blobs = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        return try DatabaseManager(inMemoryWithBlobDirectoryURL: blobs)
    }

    private func decode(_ url: URL) throws -> CloudSyncState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudSyncState.self, from: Data(contentsOf: url))
    }

    func testEditingReclassifiesPrivacyAndDoesNotExtendExpiration() throws {
        let db = try database(directory(), "db")
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "ordinary text", primaryType: .text))
        try db.updateTextContent(clipId: clip.id, newPlainText: secret, expirationMinutes: 60)
        let sensitive = try XCTUnwrap(db.fetchClip(id: clip.id))
        XCTAssertTrue(sensitive.isSensitive)
        let expiry = try XCTUnwrap(sensitive.expiresAt)
        XCTAssertGreaterThan(expiry, Date())
        try db.updateTextContent(clipId: clip.id, newPlainText: secret + " updated", expirationMinutes: 120)
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.expiresAt, expiry)
        try db.updateTextContent(clipId: clip.id, newPlainText: "ordinary again", expirationMinutes: 60)
        let ordinary = try XCTUnwrap(db.fetchClip(id: clip.id))
        XCTAssertFalse(ordinary.isSensitive)
        XCTAssertNil(ordinary.expiresAt)
    }

    func testOCRClassifiesSensitiveImageBeforeIngestionAndOnUpdate() throws {
        let db = try database(directory(), "db")
        let image = CapturedClip(plainText: "screenshot", primaryType: .image,
                                 representations: ["public.png": Data("image bytes".utf8)])
        let recognized = image.recognizingImageText { _ in self.secret }
        let captured = try db.ingestCapturedClip(recognized, expirationMinutes: 60)
        XCTAssertTrue(captured.isSensitive)
        XCTAssertNotNil(captured.expiresAt)
        let other = try db.ingestCapturedClip(CapturedClip(plainText: "another image", primaryType: .image,
                    representations: ["public.png": Data("other image bytes".utf8)]))
        try db.updateOCRText(clipId: other.id, ocrText: secret, expirationMinutes: 60)
        XCTAssertTrue(try XCTUnwrap(db.fetchClip(id: other.id)).isSensitive)
        XCTAssertNotNil(try db.fetchClip(id: other.id)?.expiresAt)
    }

    func testInsertPersistsManualSortIndex() throws {
        let db = try database(directory(), "db")
        let clip = ClipRecord(contentHash: "manual-sort-regression", plainText: "ordered", primaryType: .text, manualSortIndex: 19)
        try db.dbWriter.write { try clip.insert($0) }
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.manualSortIndex, 19)
    }

    func testOrdinarySyncObservesPeerChangesWithoutLocalChanges() async throws {
        let root = try directory()
        let a = try database(root, "a"), b = try database(root, "b")
        let sync = root.appendingPathComponent("sync")
        let wa = CloudDriveSyncWorker(databaseManager: a, customSyncDirectoryURL: sync, deviceId: "a")
        let wb = CloudDriveSyncWorker(databaseManager: b, customSyncDirectoryURL: sync, deviceId: "b")
        _ = try a.ingestCapturedClip(CapturedClip(plainText: "first peer value", primaryType: .text))
        let firstA = await wa.performSync(), firstB = await wb.performSync()
        XCTAssertEqual(firstA.status, .idle); XCTAssertEqual(firstB.status, .idle)
        let peerURL = await wa.myDeviceFileURL
        let oldDate = try FileManager.default.attributesOfItem(atPath: peerURL.path)[.modificationDate]
        _ = try a.ingestCapturedClip(CapturedClip(plainText: "second peer value", primaryType: .text))
        let secondA = await wa.performSync()
        XCTAssertEqual(secondA.status, .idle)
        if let oldDate { try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: peerURL.path) }
        let secondB = await wb.performSync()
        XCTAssertEqual(secondB.status, .idle)
        XCTAssertEqual(try b.searchClips(query: "second peer value").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sync.appendingPathComponent("sync-state-v2.json").path))
    }

    func testLegacySharedSnapshotIsImportedWithoutBeingRewritten() async throws {
        let root = try directory(), sync = root.appendingPathComponent("sync")
        let a = try database(root, "a"), b = try database(root, "b")
        let wa = CloudDriveSyncWorker(databaseManager: a, customSyncDirectoryURL: sync, deviceId: "a")
        _ = try a.ingestCapturedClip(CapturedClip(plainText: "legacy value", primaryType: .text))
        _ = await wa.performSync()
        let source = await wa.myDeviceFileURL
        let bytes = try Data(contentsOf: source)
        let legacy = sync.appendingPathComponent("sync-state-v2.json")
        try bytes.write(to: legacy)
        try FileManager.default.removeItem(at: source)
        let wb = CloudDriveSyncWorker(databaseManager: b, customSyncDirectoryURL: sync, deviceId: "b")
        let result = await wb.performSync()
        XCTAssertEqual(result.status, .idle)
        XCTAssertEqual(try b.searchClips(query: "legacy value").count, 1)
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testICloudPlaceholderRequestsDownloadAndRetries() async throws {
        let root = try directory(), sync = root.appendingPathComponent("sync")
        let db = try database(root, "db")
        let devices = sync.appendingPathComponent("devices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        let placeholder = devices.appendingPathComponent(".peer.json.icloud")
        let peer = devices.appendingPathComponent("peer.json")
        try Data().write(to: placeholder)
        let requested = AuditLockedValue<URL?>(nil)
        let worker = CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: sync, deviceId: "local",
                                          startDownload: { requested.set($0) })
        let pending = await worker.performSync()
        XCTAssertEqual(pending.status, .syncing)
        XCTAssertEqual(requested.get(), peer)
        let own = await worker.myDeviceFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        try FileManager.default.removeItem(at: placeholder)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(CloudSyncState()).write(to: peer)
        let complete = await worker.performSync()
        XCTAssertEqual(complete.status, .idle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: own.path))
    }

    func testPrivacySettingChangeWithdrawsPublishedSecretAndPreservesLocalCopy() async throws {
        let root = try directory(), sync = root.appendingPathComponent("sync")
        let a = try database(root, "a"), b = try database(root, "b")
        let exclude = AuditLockedValue(false)
        let wa = CloudDriveSyncWorker(databaseManager: a, customSyncDirectoryURL: sync, deviceId: "a",
                                      excludeSensitiveFromSync: { exclude.get() })
        let wb = CloudDriveSyncWorker(databaseManager: b, customSyncDirectoryURL: sync, deviceId: "b",
                                      excludeSensitiveFromSync: { false })
        let clip = try a.ingestCapturedClip(CapturedClip(plainText: secret, primaryType: .text))
        _ = await wa.performSync(); _ = await wb.performSync()
        XCTAssertNotNil(try b.fetchClip(id: clip.id))
        exclude.set(true)
        let withdrawal = await wa.performSync()
        XCTAssertEqual(withdrawal.status, .idle)
        let own = await wa.myDeviceFileURL
        XCTAssertTrue(try decode(own).clips.isEmpty)
        XCTAssertNotNil(try a.fetchClip(id: clip.id))
        _ = await wb.performSync(); _ = await wa.performSync()
        XCTAssertNil(try b.fetchClip(id: clip.id))
        XCTAssertNotNil(try a.fetchClip(id: clip.id))
    }
    func testRemoteDuplicateCannotReplacePrivateLocalClip() async throws {
        let root = try directory(), sync = root.appendingPathComponent("sync")
        let a = try database(root, "a"), b = try database(root, "b")
        let local = ClipRecord(id: try XCTUnwrap(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")),
                               contentHash: "private-duplicate", plainText: secret, primaryType: .text,
                               isSensitive: true)
        let remote = ClipRecord(id: try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
                                contentHash: local.contentHash, plainText: secret, primaryType: .text)
        try await a.dbWriter.write { try local.insert($0) }
        try await b.dbWriter.write { try remote.insert($0) }
        let wa = CloudDriveSyncWorker(databaseManager: a, customSyncDirectoryURL: sync, deviceId: "a",
                                      excludeSensitiveFromSync: { true })
        let wb = CloudDriveSyncWorker(databaseManager: b, customSyncDirectoryURL: sync, deviceId: "b",
                                      excludeSensitiveFromSync: { true })
        _ = await wb.performSync()
        let result = await wa.performSync()
        XCTAssertEqual(result.status, .idle)
        XCTAssertTrue(try XCTUnwrap(a.fetchClip(id: local.id)).isSensitive)
        XCTAssertNil(try a.fetchClip(id: remote.id))
        let own = await wa.myDeviceFileURL
        XCTAssertTrue(try decode(own).clips.isEmpty)
    }

}

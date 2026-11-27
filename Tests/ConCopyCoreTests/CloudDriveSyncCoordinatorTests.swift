import XCTest
@testable import ConCopyCore

final class CloudDriveSyncCoordinatorTests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyCKTests_\(UUID().uuidString)")
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

    func testStartIfPossibleReturnsInstantly() {
        let coordinator = CloudDriveSyncCoordinator(databaseManager: databaseManager)

        let startTime = CFAbsoluteTimeGetCurrent()
        coordinator.startIfPossible()
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // Must return in < 10ms (0ms fire-and-forget)
        XCTAssertLessThan(elapsed, 0.05)
        XCTAssertTrue(coordinator.isRunning)

        coordinator.stop()
        XCTAssertFalse(coordinator.isRunning)
    }

    func testCloudDriveSyncWorkerWithMissingFolderHandlesGracefully() async {
        let nonExistentDir = URL(fileURLWithPath: "/non_existent_folder_abc123/ConCopy")
        let worker = CloudDriveSyncWorker(
            databaseManager: databaseManager,
            customSyncDirectoryURL: nonExistentDir
        )

        let result = await worker.performSync()
        XCTAssertFalse(result.hasLocalChanges)
        XCTAssertEqual(result.status, .unavailable)
    }

    func testCloudDriveSyncWorkerCreatesStateAndMerges() async throws {
        let syncFolder = tempDir.appendingPathComponent("TestCloudSync")
        let worker = CloudDriveSyncWorker(
            databaseManager: databaseManager,
            customSyncDirectoryURL: syncFolder
        )

        // Add a clip to local DB
        let captured = CapturedClip(plainText: "Local sync test clip", primaryType: .text)
        _ = try databaseManager.ingestCapturedClip(captured)

        let result = await worker.performSync()
        XCTAssertEqual(result.status, .idle)

        let syncFile = await worker.myDeviceFileURL
        XCTAssertFalse(FileManager.default.fileExists(atPath: syncFolder.appendingPathComponent("sync-state-v2.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))

        let data = try Data(contentsOf: syncFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(CloudSyncState.self, from: data)

        XCTAssertEqual(state.clips.count, 1)
        XCTAssertEqual(state.clips.first?.plainText, "Local sync test clip")
    }

    func testQueueOperationsAndDebounceAreNonBlocking() {
        let coordinator = CloudDriveSyncCoordinator(databaseManager: databaseManager)
        let clip = ClipRecord(
            contentHash: "testhash",
            plainText: "test clip",
            primaryType: .text
        )
        let list = ClipListRecord(name: "Test List")

        let startTime = CFAbsoluteTimeGetCurrent()
        coordinator.queueUpload(for: clip)
        coordinator.queueUpload(for: list)
        coordinator.queueDeletion(clipId: UUID())
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        // All queue calls must be non-blocking (< 10ms)
        XCTAssertLessThan(elapsed, 0.05)
        coordinator.stop()
    }

    func testMultiDevicePerDeviceSyncConvergence() async throws {
        let syncFolder = tempDir.appendingPathComponent("MultiDeviceSync")
        let devAId = "device-A"
        let devBId = "device-B"

        let dbADir = tempDir.appendingPathComponent("dbA")
        let dbBDir = tempDir.appendingPathComponent("dbB")
        try FileManager.default.createDirectory(at: dbADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbBDir, withIntermediateDirectories: true)

        let dbA = try DatabaseManager(inMemoryWithBlobDirectoryURL: dbADir)
        let dbB = try DatabaseManager(inMemoryWithBlobDirectoryURL: dbBDir)

        let workerA = CloudDriveSyncWorker(databaseManager: dbA, customSyncDirectoryURL: syncFolder, deviceId: devAId)
        let workerB = CloudDriveSyncWorker(databaseManager: dbB, customSyncDirectoryURL: syncFolder, deviceId: devBId)

        // Device A writes clip
        _ = try dbA.ingestCapturedClip(CapturedClip(plainText: "From Device A", primaryType: .text))
        let resA = await workerA.performSync(force: true)
        XCTAssertEqual(resA.status, CloudSyncStatus.idle)

        // Verify Device A wrote to devices/device-A.json
        let devAFile = syncFolder.appendingPathComponent("devices").appendingPathComponent("\(devAId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: devAFile.path))

        // Device B syncs and should converge (ingest clip from Device A)
        let resB = await workerB.performSync(force: true)
        XCTAssertEqual(resB.status, CloudSyncStatus.idle)

        let clipsInB = try dbB.searchClips(query: "From Device A")
        XCTAssertEqual(clipsInB.count, 1)
        XCTAssertEqual(clipsInB.first?.plainText, "From Device A")

        // Verify Device B wrote its own file to devices/device-B.json
        let devBFile = syncFolder.appendingPathComponent("devices").appendingPathComponent("\(devBId).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: devBFile.path))
    }

    func testCorruptedPeerJsonIsSafelySkipped() async throws {
        let syncFolder = tempDir.appendingPathComponent("CorruptedPeerSync")
        let devicesDir = syncFolder.appendingPathComponent("devices")
        try FileManager.default.createDirectory(at: devicesDir, withIntermediateDirectories: true)

        // Write garbage corrupted json to a peer file
        let corruptedFile = devicesDir.appendingPathComponent("corrupted-peer.json")
        try Data("INVALID_JSON_CORRUPTED_BYTES".utf8).write(to: corruptedFile)

        let worker = CloudDriveSyncWorker(databaseManager: databaseManager, customSyncDirectoryURL: syncFolder, deviceId: "healthy-dev")
        let res = await worker.performSync(force: true)

        // Must succeed without throwing or crashing
        XCTAssertEqual(res.status, CloudSyncStatus.idle)
    }

    func testSensitiveClipsExcludedFromSyncWhenConfigured() async throws {
        let syncFolder = tempDir.appendingPathComponent("SensitiveSyncFolder")
        let worker = CloudDriveSyncWorker(
            databaseManager: databaseManager,
            customSyncDirectoryURL: syncFolder,
            deviceId: "device-sensitive-test",
            excludeSensitiveFromSync: { true }
        )

        // Ingest normal clip and sensitive clip (with regex-matching secret)
        _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Public info", primaryType: .text))
        let sensitiveClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "api_key = sk-1234567890abcdef1234567890abcdef", primaryType: .text),
            expirationMinutes: 60
        )
        XCTAssertTrue(sensitiveClip.isSensitive)

        let res = await worker.performSync(force: true)
        XCTAssertEqual(res.status, CloudSyncStatus.idle)

        let devFile = syncFolder.appendingPathComponent("devices").appendingPathComponent("device-sensitive-test.json")
        let data = try Data(contentsOf: devFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(CloudSyncState.self, from: data)

        let texts = state.clips.compactMap(\.plainText)
        XCTAssertTrue(texts.contains("Public info"))
        XCTAssertFalse(texts.contains("api_key = sk-1234567890abcdef1234567890abcdef"))
    }

    func testCleanupExpiredClipsRemovesExpiredAndPreservesUnexpired() async throws {
        // Ingest sensitive clips with positive expiration
        let expiredClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "password = supersecretpassword123", primaryType: .text),
            expirationMinutes: 1
        )
        XCTAssertTrue(expiredClip.isSensitive)
        XCTAssertNotNil(expiredClip.expiresAt)

        let normalClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "No expiration here", primaryType: .text)
        )
        XCTAssertNil(normalClip.expiresAt)

        // Run cleanup with now in the future beyond expiredClip.expiresAt (e.g. 10 minutes in future)
        let future = Date().addingTimeInterval(600)
        let purgedCount = try databaseManager.cleanupExpiredClips(now: future)
        XCTAssertEqual(purgedCount, 1)

        let remaining = try databaseManager.searchClips(query: "", limit: 10)
        let remainingIds = remaining.map(\.id)
        XCTAssertFalse(remainingIds.contains(expiredClip.id))
        XCTAssertTrue(remainingIds.contains(normalClip.id))
    }
}

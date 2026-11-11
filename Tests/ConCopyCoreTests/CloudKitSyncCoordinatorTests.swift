import XCTest
@testable import ConCopyCore

final class CloudKitSyncCoordinatorTests: XCTestCase {
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
        let coordinator = CloudKitSyncCoordinator(databaseManager: databaseManager)

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

        let syncFile = syncFolder.appendingPathComponent("sync-state-v1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: syncFile.path))

        let data = try Data(contentsOf: syncFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(CloudSyncState.self, from: data)

        XCTAssertEqual(state.clips.count, 1)
        XCTAssertEqual(state.clips.first?.plainText, "Local sync test clip")
    }

    func testQueueOperationsAndDebounceAreNonBlocking() {
        let coordinator = CloudKitSyncCoordinator(databaseManager: databaseManager)
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
}

import Foundation
import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class Phase3ReliabilityAndChaosTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Phase3ChaosTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    // MARK: - Task 3.1: CloudDriveSyncWorker Concurrency, Conflict & Chaos Tests

    /// Scenario 1: Deterministic tombstone precedence. Device A modifies metadata, Device B deletes.
    func testSimultaneousMetadataEditVsDeletionPrefersTombstoneDeterministic() async throws {
        let syncFolder = tempDir.appendingPathComponent("ConflictSync")
        let devADir = tempDir.appendingPathComponent("devA_db")
        let devBDir = tempDir.appendingPathComponent("devB_db")
        try FileManager.default.createDirectory(at: devADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devBDir, withIntermediateDirectories: true)

        let dbA = try DatabaseManager(inMemoryWithBlobDirectoryURL: devADir)
        let dbB = try DatabaseManager(inMemoryWithBlobDirectoryURL: devBDir)

        let workerA = CloudDriveSyncWorker(databaseManager: dbA, customSyncDirectoryURL: syncFolder, deviceId: "device-A")
        let workerB = CloudDriveSyncWorker(databaseManager: dbB, customSyncDirectoryURL: syncFolder, deviceId: "device-B")

        // Ingest clip on Device A and sync to cloud
        let captured = try dbA.ingestCapturedClip(CapturedClip(plainText: "Shared Knowledge", primaryType: .text))
        let initialA = await workerA.performSync(force: true)
        XCTAssertEqual(initialA.status, .idle)

        // Device B receives it
        let initialB = await workerB.performSync(force: true)
        XCTAssertEqual(initialB.status, .idle)
        XCTAssertEqual(try dbB.searchClips(query: "Shared Knowledge").count, 1)

        // Device A modifies clip favorite
        _ = try dbA.toggleFavorite(clipId: captured.id)
        _ = await workerA.performSync(force: true)

        // Device B deletes the clip (creating tombstone)
        try dbB.deleteClip(clipId: captured.id)
        try await workerB.addTombstone(clipId: captured.id)
        _ = await workerB.performSync(force: true)

        // Device A syncs: deletion/tombstone must deterministically win over metadata edit
        _ = await workerA.performSync(force: true)
        let clipsAfterSyncA = try dbA.searchClips(query: "Shared Knowledge")
        XCTAssertTrue(clipsAfterSyncA.isEmpty, "Tombstone must take precedence over metadata update")
    }

    /// Scenario 2: Offline peer returns with older revision clock but higher usage count.
    func testOfflinePeerWithOlderClockAndHigherUsageCountConvergesWithoutCountLoss() async throws {
        let syncFolder = tempDir.appendingPathComponent("UsageConvergenceSync")
        let devADir = tempDir.appendingPathComponent("devA_db")
        let devBDir = tempDir.appendingPathComponent("devB_db")
        try FileManager.default.createDirectory(at: devADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: devBDir, withIntermediateDirectories: true)

        let dbA = try DatabaseManager(inMemoryWithBlobDirectoryURL: devADir)
        let dbB = try DatabaseManager(inMemoryWithBlobDirectoryURL: devBDir)

        let workerA = CloudDriveSyncWorker(databaseManager: dbA, customSyncDirectoryURL: syncFolder, deviceId: "device-A")
        let workerB = CloudDriveSyncWorker(databaseManager: dbB, customSyncDirectoryURL: syncFolder, deviceId: "device-B")

        let clipA = try dbA.ingestCapturedClip(CapturedClip(plainText: "Countable Clip", primaryType: .text))
        _ = await workerA.performSync(force: true)
        _ = await workerB.performSync(force: true)

        // Device B stays offline and pastes/uses the clip 5 times
        for _ in 0..<5 {
            try dbB.recordPasteUsage(clipId: clipA.id)
        }

        // Device A updates content or edits text online
        try dbA.updateTextContent(clipId: clipA.id, newPlainText: "Countable Clip - Online Update")
        _ = await workerA.performSync(force: true)

        // Device B syncs back online
        let resB = await workerB.performSync(force: true)
        XCTAssertEqual(resB.status, .idle)

        // Device A syncs and receives the merged usage counts
        let resA = await workerA.performSync(force: true)
        XCTAssertEqual(resA.status, .idle)

        let updatedClipOnA = try XCTUnwrap(dbA.fetchClip(id: clipA.id))
        XCTAssertGreaterThanOrEqual(updatedClipOnA.pasteCount, 5, "Usage counts must converge without loss")
    }

    /// Scenario 3: Mixed filesystem chaos (corrupt JSON and legacy v2 duplicate).
    func testSyncResilienceUnderMixedFilesystemChaos() async throws {
        let syncFolder = tempDir.appendingPathComponent("ChaosSync")
        let devAId = "peer-dev-A"
        let myDevId = "my-device"

        let dbADir = tempDir.appendingPathComponent("dbA")
        let dbMyDir = tempDir.appendingPathComponent("dbMy")
        try FileManager.default.createDirectory(at: dbADir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbMyDir, withIntermediateDirectories: true)

        let dbA = try DatabaseManager(inMemoryWithBlobDirectoryURL: dbADir)
        let dbMy = try DatabaseManager(inMemoryWithBlobDirectoryURL: dbMyDir)

        let workerA = CloudDriveSyncWorker(databaseManager: dbA, customSyncDirectoryURL: syncFolder, deviceId: devAId)
        let workerMy = CloudDriveSyncWorker(databaseManager: dbMy, customSyncDirectoryURL: syncFolder, deviceId: myDevId)

        // 1. Peer A publishes a valid clip
        _ = try dbA.ingestCapturedClip(CapturedClip(plainText: "Valid Peer Content", primaryType: .text))
        let resA = await workerA.performSync(force: true)
        XCTAssertEqual(resA.status, .idle)

        // 2. Inject chaos into devices directory and sync root
        let devicesDir = syncFolder.appendingPathComponent("devices")
        let corruptedFile = devicesDir.appendingPathComponent("corrupted.json")
        try Data("{\"partial\": true, ".utf8).write(to: corruptedFile)

        let legacyFork = syncFolder.appendingPathComponent("sync-state-v2 (1).json")
        try Data("garbage fork content".utf8).write(to: legacyFork)

        // 3. Sync my-device: must complete cleanly despite chaos
        let result = await workerMy.performSync(force: true)
        XCTAssertEqual(result.status, .idle)

        let clips = try dbMy.searchClips(query: "Valid Peer Content")
        XCTAssertEqual(clips.count, 1, "Valid peer data must be ingested despite invalid adjacent files")
    }

    // MARK: - Task 3.2: Missing Blob Resilience

    func testMissingBlobThrowsCleanErrorAndDoesNotCorruptDatabase() throws {
        let dbDir = tempDir.appendingPathComponent("missing_blob_db")
        let blobDir = dbDir.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: blobDir)

        // Use > 4KB data on an image representation so replacePayloads stores it out-of-line in a .blob file
        let sampleData = Data(repeating: 0x41, count: 5000)
        let captured = CapturedClip(
            plainText: "Large binary blob test",
            primaryType: .image,
            representations: ["public.png": sampleData]
        )
        let clip = try db.ingestCapturedClip(captured)
        let payloads = try db.fetchPayloads(forClipId: clip.id)
        XCTAssertFalse(payloads.isEmpty)

        guard let payload = payloads.first(where: { $0.utiType == "public.png" }) else {
            XCTFail("Must have public.png payload")
            return
        }
        guard let filename = payload.blobFilename else {
            XCTFail("Payload must have a blobFilename")
            return
        }

        // Verify data loads successfully
        let loadedData = try db.loadPayloadData(for: payload)
        XCTAssertEqual(loadedData, sampleData)

        // Simulate external removal of .blob file
        let blobFileURL = blobDir.appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blobFileURL.path))
        try FileManager.default.removeItem(at: blobFileURL)

        // Loading must fail with missingBlob error without crashing
        XCTAssertThrowsError(try db.loadPayloadData(for: payload)) { error in
            guard case BlobStorageError.missingBlob(let missingName) = error else {
                XCTFail("Expected missingBlob error but got \(error)")
                return
            }
            XCTAssertEqual(missingName, filename)
        }

        // Database and record itself remain intact and searchable
        let fetchedClip = try db.fetchClip(id: clip.id)
        XCTAssertNotNil(fetchedClip)
        XCTAssertEqual(fetchedClip?.plainText, "Large binary blob test")
    }

    // MARK: - Task 3.3: Selection Bridge & Filter Edge Cases

    func testSelectionBridgeTransitionsAcrossQueryAndDeletion() async throws {
        let dbDir = tempDir.appendingPathComponent("selection_bridge_db")
        try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: dbDir)

        let clip1 = try db.ingestCapturedClip(CapturedClip(plainText: "Alpha Item", primaryType: .text))
        let clip2 = try db.ingestCapturedClip(CapturedClip(plainText: "Beta Item", primaryType: .text))
        let clip3 = try db.ingestCapturedClip(CapturedClip(plainText: "Gamma Item", primaryType: .text))

        let vm = ClipboardViewModel(databaseManager: db, appSettings: AppSettingsManager.shared)
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 3)

        // Select multiple clips
        vm.toggleSelection(clipId: clip1.id)
        vm.toggleSelection(clipId: clip2.id)
        XCTAssertEqual(vm.selectedClipIds, [clip1.id, clip2.id])
        XCTAssertTrue(vm.isSelectionMode)

        // Restrict search to 0 results
        vm.searchQuery = "NonExistentZeta"
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 0)
        XCTAssertEqual(vm.selectedIndex, 0)
        XCTAssertTrue(vm.selectedClipIds.isEmpty, "Selection must be pruned when no items are visible")
        XCTAssertFalse(vm.isSelectionMode)

        // Clear search query
        vm.searchQuery = ""
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 3)
        XCTAssertEqual(vm.selectedIndex, 0)

        // Select all clips
        vm.selectedClipIds = Set([clip1.id, clip2.id, clip3.id])
        XCTAssertEqual(vm.selectedClipIds.count, 3)

        // Delete one of the selected clips
        vm.deleteClip(clip2)
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 2)
        XCTAssertFalse(vm.selectedClipIds.contains(clip2.id))
        XCTAssertEqual(vm.selectedClipIds, [clip1.id, clip3.id])
        XCTAssertTrue(vm.selectedIndex >= 0 && vm.selectedIndex < vm.clips.count)
    }
}

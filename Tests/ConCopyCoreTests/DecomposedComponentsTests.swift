import Foundation
import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class DecomposedComponentsTests: XCTestCase {
    private var databaseManager: DatabaseManager!
    private var tempDirectory: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecomposedComponentsTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempDirectory)
    }

    override func tearDown() async throws {
        databaseManager = nil
        if let temp = tempDirectory {
            try? FileManager.default.removeItem(at: temp)
        }
        try await super.tearDown()
    }

    // MARK: - BatchSelectionManager Tests
    func testBatchSelectionManagerSingleAndToggle() {
        let manager = BatchSelectionManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let clips = [
            ClipRecord(id: id1, contentHash: "h1", primaryType: .text),
            ClipRecord(id: id2, contentHash: "h2", primaryType: .text),
            ClipRecord(id: id3, contentHash: "h3", primaryType: .text)
        ]

        manager.selectSingle(clipId: id2, in: clips)
        XCTAssertEqual(manager.selectedClipId(in: clips), id2)
        XCTAssertEqual(manager.selectedIndex, 1)
        XCTAssertEqual(manager.selectedClipIds, [])
        XCTAssertFalse(manager.isSelectionMode)

        manager.toggleSelection(clipId: id1, in: clips)
        XCTAssertTrue(manager.isSelectionMode)
        XCTAssertEqual(manager.selectedClipIds, [id1])
        XCTAssertEqual(manager.selectedClipId(in: clips), id1)

        manager.toggleSelection(clipId: id3, in: clips)
        XCTAssertEqual(manager.selectedClipIds, [id1, id3])

        manager.toggleSelection(clipId: id1, in: clips)
        XCTAssertEqual(manager.selectedClipIds, [id3])

        manager.pruneInvalidIds(existingIds: [id1, id2])
        XCTAssertEqual(manager.selectedClipIds, [])
    }

    func testBatchSelectionManagerRangeForwardAndBackward() {
        let manager = BatchSelectionManager()
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()
        let clips = [
            ClipRecord(id: id1, contentHash: "h1", primaryType: .text),
            ClipRecord(id: id2, contentHash: "h2", primaryType: .text),
            ClipRecord(id: id3, contentHash: "h3", primaryType: .text),
            ClipRecord(id: id4, contentHash: "h4", primaryType: .text)
        ]

        manager.selectSingle(clipId: id2, in: clips)
        XCTAssertEqual(manager.selectionAnchorId, id2)

        // Forward extension: index 1 to 3 -> covers [id2, id3, id4]
        manager.selectRange(toClipId: id4, in: clips)
        XCTAssertEqual(manager.selectedClipIds, [id2, id3, id4])
        XCTAssertEqual(manager.selectedClipId(in: clips), id4)
        XCTAssertEqual(manager.selectionAnchorId, id2)

        // Backward extension from same anchor id2 to id1 -> covers [id1, id2]
        manager.selectRange(toClipId: id1, in: clips)
        XCTAssertEqual(manager.selectedClipIds, [id1, id2])
        XCTAssertEqual(manager.selectedClipId(in: clips), id1)
        XCTAssertEqual(manager.selectionAnchorId, id2)

        manager.clearSelection(currentClipId: id1)
        XCTAssertTrue(manager.selectedClipIds.isEmpty)
        XCTAssertEqual(manager.selectionAnchorId, id1)
    }

    // MARK: - PasteQueueManager Tests
    func testPasteQueueManagerFIFOAndLIFO() {
        let manager = PasteQueueManager()
        let clipA = ClipRecord(id: UUID(), contentHash: "ha", primaryType: .text)
        let clipB = ClipRecord(id: UUID(), contentHash: "hb", primaryType: .text)
        let clipC = ClipRecord(id: UUID(), contentHash: "hc", primaryType: .text)

        XCTAssertTrue(manager.isEmpty)
        XCTAssertEqual(manager.count, 0)

        // FIFO
        manager.pasteQueueOrder = .fifo
        XCTAssertTrue(manager.enqueue(clipA))
        XCTAssertFalse(manager.enqueue(clipA)) // duplicate ignored
        XCTAssertEqual(manager.enqueue(contentsOf: [clipB, clipC]), 2)
        XCTAssertEqual(manager.count, 3)
        XCTAssertTrue(manager.isPasteQueueActive)

        let first = manager.dequeue()
        XCTAssertEqual(first?.id, clipA.id)
        XCTAssertEqual(manager.count, 2)

        // Switch to LIFO
        manager.pasteQueueOrder = .lifo
        let last = manager.dequeue()
        XCTAssertEqual(last?.id, clipC.id)
        XCTAssertEqual(manager.count, 1)

        let remaining = manager.dequeue()
        XCTAssertEqual(remaining?.id, clipB.id)
        XCTAssertTrue(manager.isEmpty)
        XCTAssertFalse(manager.isPasteQueueActive)

        XCTAssertNil(manager.dequeue())

        manager.enqueue(clipA)
        manager.clear()
        XCTAssertTrue(manager.isEmpty)
        XCTAssertFalse(manager.isPasteQueueActive)
    }

    // MARK: - SearchCoordinator Tests
    func testSearchCoordinatorCancelsOverlappingSearches() async throws {
        let coordinator = SearchCoordinator()
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Alpha query token", primaryType: .text))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Beta query token", primaryType: .text))

        var lastResults: [ClipRecord] = []
        let exp1 = expectation(description: "Second search completes")

        coordinator.searchQuery = "Alpha"
        coordinator.executeSearch(
            databaseManager: databaseManager,
            onSuccess: { results, _, _ in
                lastResults = results
            },
            onFailure: { _, _ in }
        )

        // Immediately fire second search to cancel first
        coordinator.searchQuery = "Beta"
        coordinator.executeSearch(
            databaseManager: databaseManager,
            onSuccess: { results, _, _ in
                lastResults = results
                exp1.fulfill()
            },
            onFailure: { _, _ in }
        )

        await fulfillment(of: [exp1], timeout: 2.0)
        XCTAssertEqual(lastResults.count, 1)
        XCTAssertEqual(lastResults.first?.id, clip2.id)
        XCTAssertNotEqual(lastResults.first?.id, clip1.id)
    }

    // MARK: - Runtime Expiration Cleanup Flow Tests
    func testRuntimeExpirationCleanupLogic() throws {
        let now = Date()
        let nonExpiredClip = CapturedClip(plainText: "Keep this", primaryType: .text)
        _ = try databaseManager.ingestCapturedClip(nonExpiredClip)

        // 0 expired clips
        let purgedZero = try databaseManager.cleanupExpiredClips(now: now)
        XCTAssertEqual(purgedZero, 0)

        // Ingest expired clip
        let expiredClip = CapturedClip(plainText: "Secret pass sk-1234567890abcdef1234567890abcdef", primaryType: .text)
        let inserted = try databaseManager.ingestCapturedClip(expiredClip, expirationMinutes: 1)
        XCTAssertTrue(inserted.isSensitive)

        // Not yet expired at now
        let purgedBefore = try databaseManager.cleanupExpiredClips(now: now)
        XCTAssertEqual(purgedBefore, 0)

        // Expired after 2 minutes
        let future = now.addingTimeInterval(120)
        let purgedAfter = try databaseManager.cleanupExpiredClips(now: future)
        XCTAssertEqual(purgedAfter, 1)

        // Cleaned up, subsequent purge returns 0
        let purgedAgain = try databaseManager.cleanupExpiredClips(now: future)
        XCTAssertEqual(purgedAgain, 0)
    }
}

import GRDB
import XCTest

@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class ViewModelSelectionAndFavoriteTests: XCTestCase {
    private var tempBlobDir: URL!
    private var databaseManager: DatabaseManager!
    private var viewModel: ClipboardViewModel!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBlobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyVMTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBlobDir, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempBlobDir)
        viewModel = ClipboardViewModel(databaseManager: databaseManager)
    }

    override func tearDownWithError() throws {
        viewModel = nil
        databaseManager = nil
        if let dir = tempBlobDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testClearSelectionAndToggleSelection() async throws {
        let id1 = UUID()
        let id2 = UUID()

        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)

        // Select first
        viewModel.toggleSelection(clipId: id1)
        XCTAssertTrue(viewModel.selectedClipIds.contains(id1))

        // Select second
        viewModel.toggleSelection(clipId: id2)
        XCTAssertTrue(viewModel.selectedClipIds.contains(id1))
        XCTAssertTrue(viewModel.selectedClipIds.contains(id2))

        // Deselect first via toggle (⌘+Click behavior)
        viewModel.toggleSelection(clipId: id1)
        XCTAssertFalse(viewModel.selectedClipIds.contains(id1))
        XCTAssertTrue(viewModel.selectedClipIds.contains(id2))

        // Deselect all
        viewModel.clearSelection()
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testChangingScopeClearsBatchSelection() async throws {
        let first = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "First scope item"))
        let second = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Second scope item"))
        let list = try databaseManager.createList(name: "Work")
        viewModel.loadLists()
        await viewModel.waitForPendingLoads()

        let scopeChanges: [(String, () -> Void)] = [
            ("All", { self.viewModel.selectAllClips() }),
            ("Favorites", { self.viewModel.selectFavorites() }),
            ("Snippets", { self.viewModel.selectSnippets() }),
            ("Personal list", { self.viewModel.selectList(list.id) }),
        ]

        for (name, changeScope) in scopeChanges {
            viewModel.clearSelection()
            viewModel.selectAllClips()
            await viewModel.waitForPendingLoads()
            viewModel.toggleSelection(clipId: first.id)
            viewModel.toggleSelection(clipId: second.id)
            XCTAssertEqual(viewModel.selectedClipIds.count, 2)

            changeScope()

            XCTAssertTrue(viewModel.selectedClipIds.isEmpty, "Switching to \(name) must not retain a hidden batch")
        }
    }

    func testToggleSelectionWhenEmptyDoesNotIncludeDefaultActiveIndex() async throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Record \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 5)
        XCTAssertEqual(viewModel.selectedIndex, 0)  // default active index is 0
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)

        // Click checkbox on index 3
        let targetClip = viewModel.clips[3]
        viewModel.toggleSelection(clipId: targetClip.id)

        // Must ONLY select index 3, without including index 0
        XCTAssertEqual(viewModel.selectedClipIds.count, 1)
        XCTAssertTrue(viewModel.selectedClipIds.contains(targetClip.id))
        XCTAssertFalse(viewModel.selectedClipIds.contains(viewModel.clips[0].id))
        XCTAssertEqual(viewModel.selectedClipId, targetClip.id)
    }

    func testShiftClickRangeSelectionForwardAndBackward() async throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Clip \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 5)

        // 1. Single click on clip at index 1
        viewModel.selectSingle(clipId: viewModel.clips[1].id)
        XCTAssertEqual(viewModel.selectedClipId, viewModel.clips[1].id)
        XCTAssertEqual(viewModel.selectionAnchorId, viewModel.clips[1].id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)

        // 2. Shift+Click forward on index 3 -> range [1...3] (3 items)
        viewModel.selectRange(to: viewModel.clips[3])
        XCTAssertEqual(viewModel.selectedClipIds.count, 3)
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[1].id))
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[2].id))
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[3].id))
        XCTAssertEqual(viewModel.selectionAnchorId, viewModel.clips[1].id)

        // 3. Shift+Click backward on index 0 -> range [0...1] (2 items)
        viewModel.selectRange(to: viewModel.clips[0])
        XCTAssertEqual(viewModel.selectedClipIds.count, 2)
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[0].id))
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[1].id))
        XCTAssertEqual(viewModel.selectionAnchorId, viewModel.clips[1].id)
    }

    func testArrowSelectionWrapsAndShiftStopsAtBoundaries() async throws {
        viewModel.moveSelectionUp()
        viewModel.moveSelectionDown()
        XCTAssertTrue(viewModel.clips.isEmpty)

        for i in 1...3 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Wrap item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 3)
        let first = try XCTUnwrap(viewModel.clips.first)
        let last = try XCTUnwrap(viewModel.clips.last)
        viewModel.selectSingle(clipId: first.id)

        viewModel.moveSelectionUp()
        XCTAssertEqual(viewModel.selectedClipId, last.id)
        XCTAssertEqual(viewModel.selectionAnchorId, last.id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)

        viewModel.moveSelectionDown()
        XCTAssertEqual(viewModel.selectedClipId, first.id)
        XCTAssertEqual(viewModel.selectionAnchorId, first.id)

        viewModel.moveSelectionUp(expandSelection: true)
        XCTAssertEqual(viewModel.selectedClipId, first.id)
        XCTAssertEqual(viewModel.selectedClipIds, [first.id])

        viewModel.selectSingle(clipId: last.id)
        viewModel.moveSelectionDown(expandSelection: true)
        XCTAssertEqual(viewModel.selectedClipId, last.id)
        XCTAssertEqual(viewModel.selectedClipIds, [last.id])

        viewModel.clips = [first]
        viewModel.selectSingle(clipId: first.id)
        viewModel.moveSelectionUp()
        viewModel.moveSelectionDown()
        XCTAssertEqual(viewModel.selectedClipId, first.id)
    }

    func testArrowWrapReachesActualLastClipBeyondFirstPage() async throws {
        for i in 1...225 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Paged item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        let orderedClips = try databaseManager.searchClips(limit: 300)
        let first = try XCTUnwrap(orderedClips.first)
        let last = try XCTUnwrap(orderedClips.last)
        XCTAssertEqual(viewModel.clips.count, 100)
        XCTAssertTrue(viewModel.hasMoreClips)
        viewModel.selectSingle(clipId: first.id)

        viewModel.moveSelectionUp()
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.clips.count, 225)
        XCTAssertFalse(viewModel.hasMoreClips)
        XCTAssertEqual(viewModel.selectedClipId, last.id)
        XCTAssertEqual(viewModel.selectionAnchorId, last.id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)

        viewModel.moveSelectionDown()
        XCTAssertEqual(viewModel.selectedClipId, first.id)
    }

    func testRapidArrowMovesContinueAcrossPagesBeforeWrapping() async throws {
        for i in 1...225 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Rapid item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        let orderedClips = try databaseManager.searchClips(limit: 300)
        viewModel.selectSingle(clipId: orderedClips[99].id)

        viewModel.moveSelectionDown()
        viewModel.moveSelectionDown()
        viewModel.moveSelectionUp()
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.selectedClipId, orderedClips[100].id)
        XCTAssertEqual(viewModel.clips.count, 200)
        XCTAssertTrue(viewModel.hasMoreClips)

        viewModel.selectSingle(clipId: orderedClips[199].id)
        for _ in 0..<26 {
            viewModel.moveSelectionDown()
        }
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.clips.count, 225)
        XCTAssertFalse(viewModel.hasMoreClips)
        XCTAssertEqual(viewModel.selectedClipId, orderedClips[0].id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testShiftArrowSelectionExtendsAcrossPageBoundary() async throws {
        for i in 1...225 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Range item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        let orderedClips = try databaseManager.searchClips(limit: 300)
        viewModel.selectSingle(clipId: orderedClips[99].id)

        viewModel.moveSelectionDown(expandSelection: true)
        viewModel.moveSelectionDown(expandSelection: true)
        viewModel.moveSelectionUp(expandSelection: true)
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.selectedClipId, orderedClips[100].id)
        XCTAssertEqual(viewModel.selectionAnchorId, orderedClips[99].id)
        XCTAssertEqual(viewModel.selectedClipIds, Set(orderedClips[99...100].map(\.id)))

        viewModel.moveSelectionUp()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.selectedClipId, orderedClips[99].id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testPendingArrowWrapIsCancelledByQueryChange() async throws {
        for i in 1...225 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Search item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        viewModel.selectSingle(clipId: try XCTUnwrap(viewModel.clips.first).id)

        viewModel.moveSelectionUp()
        viewModel.searchQuery = "Search item 224"
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.clips.first?.plainText, "Search item 224")
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testShiftArrowKeysExtensionAndContraction() async throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 5)

        // Select starting at index 1
        viewModel.selectSingle(clipId: viewModel.clips[1].id)
        XCTAssertEqual(viewModel.selectedIndex, 1)

        // Shift + Down Arrow -> extend to index 2
        viewModel.moveSelection(by: 1, extendSelection: true)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedClipIds.count, 2)
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[1].id))
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[2].id))

        // Shift + Down Arrow -> extend to index 3
        viewModel.moveSelection(by: 1, extendSelection: true)
        XCTAssertEqual(viewModel.selectedIndex, 3)
        XCTAssertEqual(viewModel.selectedClipIds.count, 3)

        // Shift + Up Arrow -> contract back to index 2 (Finder behavior)
        viewModel.moveSelection(by: -1, extendSelection: true)
        XCTAssertEqual(viewModel.selectedIndex, 2)
        XCTAssertEqual(viewModel.selectedClipIds.count, 2)
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[1].id))
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[2].id))
        XCTAssertFalse(viewModel.selectedClipIds.contains(viewModel.clips[3].id))
    }

    func testShiftRangeCombinedWithCommandClickToggle() async throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Entry \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        // 1. Start at 0, Shift+Click to 3 -> items 0, 1, 2, 3
        viewModel.selectSingle(clipId: viewModel.clips[0].id)
        viewModel.selectRange(to: viewModel.clips[3])
        XCTAssertEqual(viewModel.selectedClipIds.count, 4)

        // 2. Cmd+Click on item 2 -> exclude item 2
        viewModel.toggleSelection(for: viewModel.clips[2])
        XCTAssertEqual(viewModel.selectedClipIds.count, 3)
        XCTAssertFalse(viewModel.selectedClipIds.contains(viewModel.clips[2].id))

        // 3. Cmd+Click on item 4 -> include item 4
        viewModel.toggleSelection(for: viewModel.clips[4])
        XCTAssertEqual(viewModel.selectedClipIds.count, 4)
        XCTAssertTrue(viewModel.selectedClipIds.contains(viewModel.clips[4].id))
    }

    func testOrderedConcatenationBatchCopy() async throws {
        for i in 1...4 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Row \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        // Select the first item explicitly, then toggle another item
        let clip1 = viewModel.clips[1]
        let clip3 = viewModel.clips[3]

        viewModel.toggleSelection(for: clip1)
        viewModel.toggleSelection(for: clip3)

        let ordered = viewModel.clips.filter { viewModel.selectedClipIds.contains($0.id) }
        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].id, clip1.id)
        XCTAssertEqual(ordered[1].id, clip3.id)

        let customPasteboard = NSPasteboard.withUniqueName()
        try await viewModel.pasteInjector.copyBatchToPasteboard(
            clips: ordered,
            mode: .concatenated(separator: .newline),
            transformation: .none,
            databaseManager: databaseManager,
            pasteboard: customPasteboard
        )

        let pastedText = customPasteboard.string(forType: .string)
        let expectedText = "\(ordered[0].plainText ?? "")\n\(ordered[1].plainText ?? "")"
        XCTAssertEqual(pastedText, expectedText)
    }

    func testToggleFavoriteUpdatesDatabaseAndState() async throws {
        let captured = CapturedClip(
            plainText: "Test favorite toggle",
            primaryType: .text,
            sourceAppBundleId: "com.apple.Safari"
        )
        let inserted = try databaseManager.ingestCapturedClip(captured)
        XCTAssertFalse(inserted.isFavorite)

        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertFalse(viewModel.clips[0].isFavorite)

        // Toggle to true
        viewModel.toggleFavorite(clip: viewModel.clips[0])
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertTrue(viewModel.clips[0].isFavorite)

        let inDb = try databaseManager.fetchClip(id: inserted.id)
        XCTAssertEqual(inDb?.isFavorite, true)

        // Toggle back to false
        viewModel.toggleFavorite(clip: viewModel.clips[0])
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertFalse(viewModel.clips[0].isFavorite)

        let inDbAfter = try databaseManager.fetchClip(id: inserted.id)
        XCTAssertEqual(inDbAfter?.isFavorite, false)
    }

    func testFavoriteClipDoesNotJumpToTopWhenReCopied() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Old Clip 1", primaryType: .text)
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        let clip2 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Newer Clip 2", primaryType: .text)
        )

        _ = try databaseManager.toggleFavorite(clipId: clip1.id)
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.clips.first?.id, clip2.id)
        XCTAssertEqual(viewModel.clips.last?.id, clip1.id)

        try await Task.sleep(nanoseconds: 20_000_000)
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Old Clip 1", primaryType: .text)
        )
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        XCTAssertEqual(viewModel.clips.first?.id, clip2.id)
        XCTAssertEqual(viewModel.clips.last?.id, clip1.id)
    }

    func testToggleFavoriteDoesNotBumpUpdatedAtOrMoveClipToTop() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Historical Clip", primaryType: .text)
        )
        try await Task.sleep(nanoseconds: 20_000_000)
        let clip2 = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Recent Clip", primaryType: .text)
        )

        let initialUpdatedAt = clip1.updatedAt

        let toggled = try databaseManager.toggleFavorite(clipId: clip1.id)
        XCTAssertTrue(toggled.isFavorite)
        XCTAssertEqual(toggled.updatedAt.timeIntervalSince1970, initialUpdatedAt.timeIntervalSince1970, accuracy: 0.01)

        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.first?.id, clip2.id)
    }

    func testUnfavoriteClipDoesNotResurrectFavoriteWhenReCopied() async throws {
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Important Text", primaryType: .text)
        )
        _ = try databaseManager.toggleFavorite(clipId: clip.id)
        let inDbFav = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(inDbFav?.isFavorite, true)

        _ = try databaseManager.toggleFavorite(clipId: clip.id)
        let inDbUnfav = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(inDbUnfav?.isFavorite, false)

        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Important Text", primaryType: .text)
        )
        let inDbAfterRecopy = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(inDbAfterRecopy?.isFavorite, false)
    }

    func testAssignMovingClipToAllClearsFavorite() async throws {
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Clip in List and Favorite", primaryType: .text)
        )
        _ = try databaseManager.toggleFavorite(clipId: clip.id)
        let list = try databaseManager.createList(name: "Test List")
        _ = try databaseManager.assignClip(clipId: clip.id, toListId: list.id)

        let inDbBefore = try databaseManager.fetchClip(id: clip.id)
        XCTAssertTrue(inDbBefore?.isFavorite ?? false)
        XCTAssertEqual(inDbBefore?.listId, list.id)

        viewModel.movingClip = inDbBefore
        viewModel.assignMovingClipToAll()
        await viewModel.waitForPendingLoads()

        let inDbAfter = try databaseManager.fetchClip(id: clip.id)
        XCTAssertFalse(inDbAfter?.isFavorite ?? true)
        XCTAssertNil(inDbAfter?.listId)
    }

    func testOnOpenSettingsCallbackCanBeInvoked() async throws {
        var didOpen = false
        viewModel.onOpenSettings = {
            didOpen = true
        }

        viewModel.onOpenSettings?()
        XCTAssertTrue(didOpen)
    }

    func testNewCapturedClipUpdatesSelectionToMostRecent() async throws {
        // 1. Ingest initial clips
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Historical Clip 1", primaryType: .text)
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Historical Clip 2", primaryType: .text)
        )
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.clips.count, 2)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        // 2. Select historical clip at index 1 (Clip X)
        let historicalClipX = viewModel.clips[1]
        viewModel.selectSingle(clipId: historicalClipX.id)
        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedClipId, historicalClipX.id)

        // 3. New acquisition arrives (Clip Y)
        try await Task.sleep(nanoseconds: 50_000_000)
        let clipY = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "New Captured Clip Y", primaryType: .text)
        )
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        // 4. Must automatically select Clip Y (index 0)
        XCTAssertEqual(viewModel.clips.first?.id, clipY.id)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedClipId, clipY.id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testSelectMostRecentClipResetsSelectionToFirst() async throws {
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Clip A", primaryType: .text)
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Clip B", primaryType: .text)
        )
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        viewModel.selectedIndex = 1
        XCTAssertEqual(viewModel.selectedIndex, 1)

        viewModel.selectMostRecentClip()
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedClipId, viewModel.clips.first?.id)
    }

    func testAssignClipToListDoesNotMarkFavoriteAndProtectsFromPruning() async throws {
        // 1. Ingest normal clip
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "List Item Without Star", primaryType: .text)
        )
        XCTAssertFalse(clip.isFavorite)
        XCTAssertNil(clip.listId)

        // 2. Create list and assign clip
        let list = try databaseManager.createList(name: "Projects")
        viewModel.loadLists()
        await viewModel.waitForPendingLoads()
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        viewModel.assignClipToList(clip: clip, listId: list.id)
        await viewModel.waitForPendingLoads()

        // Verify clip belongs to list and is NOT favorite
        let updated = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.listId, list.id)
        XCTAssertFalse(updated?.isFavorite ?? true)

        // Verify Favorites tab does NOT contain this clip
        viewModel.selectFavorites()
        await viewModel.waitForPendingLoads()
        XCTAssertFalse(viewModel.clips.contains(where: { $0.id == clip.id }))

        // Verify List tab DOES contain this clip
        viewModel.selectList(list.id)
        await viewModel.waitForPendingLoads()
        XCTAssertTrue(viewModel.clips.contains(where: { $0.id == clip.id }))

        // 3. Test pruning protection
        // Backdate clip to 60 days ago
        let oldDate = Date().addingTimeInterval(-60 * 86400)
        try await databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET createdAt = ? WHERE id = ?",
                arguments: [oldDate, clip.id.uuidString.lowercased()]
            )
        }

        // Run pruning olderThanDays: 30
        let pruned = try databaseManager.pruneClips(olderThanDays: 30)
        XCTAssertEqual(pruned, 0)  // Should NOT prune list item

        let stillExists = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNotNil(stillExists)
        XCTAssertEqual(stillExists?.listId, list.id)
        XCTAssertFalse(stillExists?.isFavorite ?? true)
    }

    func testSnippetManagementAndFilteringLifecycle() async throws {
        // 1. Create snippets
        await viewModel.saveSnippet(shortcut: ";mail", content: "me@example.com", title: "Email Personale")
        await viewModel.saveSnippet(shortcut: ";tel", content: "+39 123 456789", title: "Numero Telefono")
        await viewModel.saveSnippet(shortcut: ";addr", content: "Via Roma 10, Milano", title: "Indirizzo")

        viewModel.selectSnippets()
        await viewModel.waitForPendingLoads()
        XCTAssertTrue(viewModel.isSnippetsOnly)
        XCTAssertEqual(viewModel.snippets.count, 3)
        XCTAssertEqual(viewModel.filteredSnippets.count, 3)

        // 2. Search filtering
        viewModel.searchQuery = "email"
        XCTAssertEqual(viewModel.filteredSnippets.count, 1)
        XCTAssertEqual(viewModel.filteredSnippets.first?.shortcut, ";mail")

        viewModel.searchQuery = ";tel"
        XCTAssertEqual(viewModel.filteredSnippets.count, 1)
        XCTAssertEqual(viewModel.filteredSnippets.first?.shortcut, ";tel")

        viewModel.searchQuery = "Milano"
        XCTAssertEqual(viewModel.filteredSnippets.count, 1)
        XCTAssertEqual(viewModel.filteredSnippets.first?.content, "Via Roma 10, Milano")

        viewModel.searchQuery = ""
        XCTAssertEqual(viewModel.filteredSnippets.count, 3)

        // 3. Keyboard navigation in snippets
        viewModel.selectedSnippetIndex = 0
        viewModel.moveSelection(by: 1, extendSelection: false)
        XCTAssertEqual(viewModel.selectedSnippetIndex, 1)

        viewModel.moveSelection(by: 1, extendSelection: false)
        XCTAssertEqual(viewModel.selectedSnippetIndex, 2)

        viewModel.moveSelection(by: 1, extendSelection: false)  // Wrap to first
        XCTAssertEqual(viewModel.selectedSnippetIndex, 0)

        viewModel.moveSelection(by: -1, extendSelection: false)
        XCTAssertEqual(viewModel.selectedSnippetIndex, 2)

        // 4. Update snippet
        let snippetToEdit = viewModel.snippets.first { $0.shortcut == ";mail" }!
        await viewModel.saveSnippet(
            shortcut: ";email", content: "new@example.com", title: "Nuova Email", existingId: snippetToEdit.id)
        viewModel.loadSnippets()
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.snippets.count, 3)
        let updatedSnippet = viewModel.snippets.first { $0.id == snippetToEdit.id }
        XCTAssertEqual(updatedSnippet?.shortcut, ";email")
        XCTAssertEqual(updatedSnippet?.content, "new@example.com")
        XCTAssertEqual(updatedSnippet?.title, "Nuova Email")

        // 5. Delete snippet
        viewModel.deleteSnippet(updatedSnippet!)
        await viewModel.waitForPendingLoads()
        XCTAssertEqual(viewModel.snippets.count, 2)
        XCTAssertFalse(viewModel.snippets.contains(where: { $0.id == snippetToEdit.id }))

        // 6. Convert Clip to Snippet
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Test snippet from clip", primaryType: .text)
        )
        viewModel.createSnippetFromClip(clip)
        XCTAssertTrue(viewModel.isSnippetEditorPresented)
        XCTAssertEqual(viewModel.editingSnippet?.content, "Test snippet from clip")

        // 7. Test Move Dialog (⌘M) with Snippet Option (⌘2, or ⌘⌥2 if swapped)
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()
        viewModel.selectedIndex = 0
        viewModel.promptMoveSelectedClipToList()
        XCTAssertNotNil(viewModel.movingClip)
        XCTAssertEqual(viewModel.movingClip?.id, clip.id)

        // Select Option 2 (Snippet destination)
        viewModel.assignMovingClip(toOptionIndex: 2)
        await viewModel.waitForPendingLoads()
        XCTAssertNil(viewModel.movingClip)
        XCTAssertTrue(viewModel.isSnippetEditorPresented)
        XCTAssertEqual(viewModel.editingSnippet?.content, "Test snippet from clip")

        // 8. Test Move Dialog Option 1 (Favorite toggle) and Option A (All Clips)
        viewModel.promptMoveSelectedClipToList()
        XCTAssertFalse(clip.isFavorite)
        viewModel.assignMovingClip(toOptionIndex: 1)
        await viewModel.waitForPendingLoads()
        XCTAssertNil(viewModel.movingClip)
        let updatedClip = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(updatedClip?.isFavorite, true)

        viewModel.promptMoveSelectedClipToList()
        viewModel.assignMovingClipToAll()
        await viewModel.waitForPendingLoads()
        XCTAssertNil(viewModel.movingClip)
        let unassignedClip = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNil(unassignedClip?.listId)
    }

    func testCopySelectedToPasteboardSingleAndBatch() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Alpha Record", primaryType: .text))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Beta Record", primaryType: .text))
        viewModel.loadClips()
        await viewModel.waitForPendingLoads()

        var panelClosed = false
        viewModel.onClosePanel = {
            panelClosed = true
        }

        // 1. Copy single selected
        viewModel.selectedIndex = 0
        panelClosed = false
        viewModel.copySelectedToPasteboard()
        await viewModel.waitForPendingLoads()
        XCTAssertTrue(panelClosed)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Beta Record")

        // 2. Copy batch selected
        viewModel.selectedClipIds = [clip1.id, clip2.id]
        panelClosed = false
        viewModel.copySelectedToPasteboard()
        await viewModel.waitForPendingLoads()
        XCTAssertTrue(panelClosed)
        let batchContent = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(batchContent.contains("Beta Record") && batchContent.contains("Alpha Record"))
    }
}

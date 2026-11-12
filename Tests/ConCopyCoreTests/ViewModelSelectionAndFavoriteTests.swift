import XCTest
import GRDB
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

    func testClearSelectionAndToggleSelection() {
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

    func testToggleSelectionWhenEmptyDoesNotIncludeDefaultActiveIndex() throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Record \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
        XCTAssertEqual(viewModel.clips.count, 5)
        XCTAssertEqual(viewModel.selectedIndex, 0) // default active index is 0
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

    func testShiftClickRangeSelectionForwardAndBackward() throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Clip \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
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

    func testShiftArrowKeysExtensionAndContraction() throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Item \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()
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

    func testShiftRangeCombinedWithCommandClickToggle() throws {
        for i in 1...5 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Entry \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()

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

    func testOrderedConcatenationBatchCopy() throws {
        for i in 1...4 {
            _ = try databaseManager.ingestCapturedClip(
                CapturedClip(plainText: "Row \(i)", primaryType: .text)
            )
        }
        viewModel.loadClips()

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
        try viewModel.pasteInjector.copyBatchToPasteboard(
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

    func testToggleFavoriteUpdatesDatabaseAndState() throws {
        let captured = CapturedClip(
            plainText: "Test favorite toggle",
            primaryType: .text,
            sourceAppBundleId: "com.apple.Safari"
        )
        let inserted = try databaseManager.ingestCapturedClip(captured)
        XCTAssertFalse(inserted.isFavorite)

        viewModel.loadClips()
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertFalse(viewModel.clips[0].isFavorite)

        // Toggle to true
        viewModel.toggleFavorite(clip: viewModel.clips[0])
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertTrue(viewModel.clips[0].isFavorite)

        let inDb = try databaseManager.fetchClip(id: inserted.id)
        XCTAssertEqual(inDb?.isFavorite, true)

        // Toggle back to false
        viewModel.toggleFavorite(clip: viewModel.clips[0])
        XCTAssertEqual(viewModel.clips.count, 1)
        XCTAssertFalse(viewModel.clips[0].isFavorite)

        let inDbAfter = try databaseManager.fetchClip(id: inserted.id)
        XCTAssertEqual(inDbAfter?.isFavorite, false)
    }

    func testOnOpenSettingsCallbackCanBeInvoked() {
        var didOpen = false
        viewModel.onOpenSettings = {
            didOpen = true
        }

        viewModel.onOpenSettings?()
        XCTAssertTrue(didOpen)
    }

    func testNewCapturedClipUpdatesSelectionToMostRecent() throws {
        // 1. Ingest initial clips
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Historical Clip 1", primaryType: .text)
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Historical Clip 2", primaryType: .text)
        )
        viewModel.loadClips()
        XCTAssertEqual(viewModel.clips.count, 2)
        XCTAssertEqual(viewModel.selectedIndex, 0)

        // 2. Select historical clip at index 1 (Clip X)
        let historicalClipX = viewModel.clips[1]
        viewModel.selectSingle(clipId: historicalClipX.id)
        XCTAssertEqual(viewModel.selectedIndex, 1)
        XCTAssertEqual(viewModel.selectedClipId, historicalClipX.id)

        // 3. New acquisition arrives (Clip Y)
        Thread.sleep(forTimeInterval: 0.05)
        let clipY = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "New Captured Clip Y", primaryType: .text)
        )
        viewModel.loadClips()

        // 4. Must automatically select Clip Y (index 0)
        XCTAssertEqual(viewModel.clips.first?.id, clipY.id)
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedClipId, clipY.id)
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
    }

    func testSelectMostRecentClipResetsSelectionToFirst() throws {
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Clip A", primaryType: .text)
        )
        _ = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Clip B", primaryType: .text)
        )
        viewModel.loadClips()
        viewModel.selectedIndex = 1
        XCTAssertEqual(viewModel.selectedIndex, 1)

        viewModel.selectMostRecentClip()
        XCTAssertEqual(viewModel.selectedIndex, 0)
        XCTAssertEqual(viewModel.selectedClipId, viewModel.clips.first?.id)
    }

    func testAssignClipToListDoesNotMarkFavoriteAndProtectsFromPruning() throws {
        // 1. Ingest normal clip
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "List Item Without Star", primaryType: .text)
        )
        XCTAssertFalse(clip.isFavorite)
        XCTAssertNil(clip.listId)

        // 2. Create list and assign clip
        let list = try databaseManager.createList(name: "Projects")
        viewModel.loadLists()
        viewModel.loadClips()

        viewModel.assignClipToList(clip: clip, listId: list.id)

        // Verify clip belongs to list and is NOT favorite
        let updated = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.listId, list.id)
        XCTAssertFalse(updated?.isFavorite ?? true)

        // Verify Favorites tab does NOT contain this clip
        viewModel.selectFavorites()
        XCTAssertFalse(viewModel.clips.contains(where: { $0.id == clip.id }))

        // Verify List tab DOES contain this clip
        viewModel.selectList(list.id)
        XCTAssertTrue(viewModel.clips.contains(where: { $0.id == clip.id }))

        // 3. Test pruning protection
        // Backdate clip to 60 days ago
        let oldDate = Date().addingTimeInterval(-60 * 86400)
        try databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET createdAt = ? WHERE id = ?",
                arguments: [oldDate, clip.id.uuidString.lowercased()]
            )
        }

        // Run pruning olderThanDays: 30
        let pruned = try databaseManager.pruneClips(olderThanDays: 30)
        XCTAssertEqual(pruned, 0) // Should NOT prune list item

        let stillExists = try databaseManager.fetchClip(id: clip.id)
        XCTAssertNotNil(stillExists)
        XCTAssertEqual(stillExists?.listId, list.id)
        XCTAssertFalse(stillExists?.isFavorite ?? true)
    }

    func testSnippetManagementAndFilteringLifecycle() throws {
        // 1. Create snippets
        viewModel.saveSnippet(shortcut: ";mail", content: "me@example.com", title: "Email Personale")
        viewModel.saveSnippet(shortcut: ";tel", content: "+39 123 456789", title: "Numero Telefono")
        viewModel.saveSnippet(shortcut: ";addr", content: "Via Roma 10, Milano", title: "Indirizzo")

        viewModel.selectSnippets()
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

        viewModel.moveSelection(by: 1, extendSelection: false) // bounded to max
        XCTAssertEqual(viewModel.selectedSnippetIndex, 2)

        viewModel.moveSelection(by: -1, extendSelection: false)
        XCTAssertEqual(viewModel.selectedSnippetIndex, 1)

        // 4. Update snippet
        let snippetToEdit = viewModel.snippets.first { $0.shortcut == ";mail" }!
        viewModel.saveSnippet(shortcut: ";email", content: "new@example.com", title: "Nuova Email", existingId: snippetToEdit.id)
        viewModel.loadSnippets()
        XCTAssertEqual(viewModel.snippets.count, 3)
        let updatedSnippet = viewModel.snippets.first { $0.id == snippetToEdit.id }
        XCTAssertEqual(updatedSnippet?.shortcut, ";email")
        XCTAssertEqual(updatedSnippet?.content, "new@example.com")
        XCTAssertEqual(updatedSnippet?.title, "Nuova Email")

        // 5. Delete snippet
        viewModel.deleteSnippet(updatedSnippet!)
        XCTAssertEqual(viewModel.snippets.count, 2)
        XCTAssertFalse(viewModel.snippets.contains(where: { $0.id == snippetToEdit.id }))

        // 6. Convert Clip to Snippet
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Test snippet from clip", primaryType: .text)
        )
        viewModel.createSnippetFromClip(clip)
        XCTAssertTrue(viewModel.isSnippetEditorPresented)
        XCTAssertEqual(viewModel.editingSnippet?.content, "Test snippet from clip")

        // 7. Test Move Dialog (⌘M) with Snippet Option (⌥2)
        viewModel.loadClips()
        viewModel.selectedIndex = 0
        viewModel.promptMoveSelectedClipToList()
        XCTAssertNotNil(viewModel.movingClip)
        XCTAssertEqual(viewModel.movingClip?.id, clip.id)

        // Select Option 2 (Snippet destination)
        viewModel.assignMovingClip(toOptionIndex: 2)
        XCTAssertNil(viewModel.movingClip)
        XCTAssertTrue(viewModel.isSnippetEditorPresented)
        XCTAssertEqual(viewModel.editingSnippet?.content, "Test snippet from clip")
    }
}

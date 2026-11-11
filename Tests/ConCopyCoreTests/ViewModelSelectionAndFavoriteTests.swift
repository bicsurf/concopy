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
}

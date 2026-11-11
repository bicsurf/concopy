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
        XCTAssertEqual(viewModel.selectedClipIds.count, 1)

        // Select second
        viewModel.toggleSelection(clipId: id2)
        XCTAssertTrue(viewModel.selectedClipIds.contains(id1))
        XCTAssertTrue(viewModel.selectedClipIds.contains(id2))
        XCTAssertEqual(viewModel.selectedClipIds.count, 2)

        // Deselect first via toggle (⌘+Click behavior)
        viewModel.toggleSelection(clipId: id1)
        XCTAssertFalse(viewModel.selectedClipIds.contains(id1))
        XCTAssertTrue(viewModel.selectedClipIds.contains(id2))
        XCTAssertEqual(viewModel.selectedClipIds.count, 1)

        // Deselect all
        viewModel.clearSelection()
        XCTAssertTrue(viewModel.selectedClipIds.isEmpty)
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

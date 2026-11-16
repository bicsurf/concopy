import AppKit
import XCTest
import GRDB
@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class ClipboardViewModelTests: XCTestCase {
    private var tempBlobDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBlobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyVMClickTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempBlobDir, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempBlobDir)
    }

    override func tearDownWithError() throws {
        databaseManager = nil
        if let dir = tempBlobDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testSingleClickWithDirectPasteEnabledCopiesClosesAndPastes() async throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        settings.isDirectPasteEnabled = true
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Hello Direct Paste", primaryType: .text))
        vm.loadClips()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip)

        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(vm.selectedClipId, clip.id)
        XCTAssertTrue(vm.selectedClipIds.isEmpty)
        XCTAssertTrue(panelClosed, "Panel must close when isDirectPasteEnabled is true")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1, "Must inject Command+V paste event")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Hello Direct Paste")
    }

    func testSingleClickWithDirectPasteDisabledCopiesWithoutClosingPanel() throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        settings.isDirectPasteEnabled = false
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Copy Only Mode", primaryType: .text))
        vm.loadClips()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip)

        XCTAssertEqual(vm.selectedClipId, clip.id)
        XCTAssertTrue(vm.selectedClipIds.isEmpty)
        XCTAssertFalse(panelClosed, "Panel must NOT close when isDirectPasteEnabled is false")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0, "Must not inject paste command")
        XCTAssertEqual(vm.copiedClipId, clip.id, "Must set copiedClipId for visual feedback")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Copy Only Mode")
    }

    func testShiftClickUpdatesSelectedClipIdsWithoutCopyOrClosing() throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        var clips: [ClipRecord] = []
        for i in 1...4 {
            let c = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Item \(i)", primaryType: .text))
            clips.append(c)
        }
        vm.loadClips()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        NSPasteboard.general.clearContents()

        let targetClip = vm.clips[2]
        vm.handleRowClick(clip: targetClip, shiftHeld: true)

        XCTAssertFalse(panelClosed, "Shift+Click must not close panel")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0, "Shift+Click must not paste")
        XCTAssertNil(vm.copiedClipId, "Shift+Click must not trigger copied state")
        XCTAssertEqual(vm.selectedClipIds.count, 3, "Range [0...2] should contain 3 items")
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[0].id))
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[1].id))
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[2].id))
        XCTAssertEqual(vm.selectedClipId, targetClip.id)
    }

    func testShiftClickWhenNoInitialSelectionSelectsSingleRecord() throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "A", primaryType: .text))
        let _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "B", primaryType: .text))
        vm.loadClips()

        vm.selectedIndex = -1
        XCTAssertNil(vm.selectedClipId)

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip1, shiftHeld: true)

        XCTAssertFalse(panelClosed)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)
        XCTAssertNil(vm.copiedClipId)
        XCTAssertEqual(vm.selectedClipIds, [clip1.id])
        XCTAssertEqual(vm.selectedClipId, clip1.id)
    }

    func testCommandClickTogglesSelectionWithoutCopyOrClosing() throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "A", primaryType: .text))
        let _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "B", primaryType: .text))
        vm.loadClips()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip1, commandHeld: true)
        XCTAssertFalse(panelClosed)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)
        XCTAssertTrue(vm.selectedClipIds.contains(clip1.id))

        vm.handleRowClick(clip: clip1, commandHeld: true)
        XCTAssertFalse(panelClosed)
        XCTAssertFalse(vm.selectedClipIds.contains(clip1.id))
    }
}

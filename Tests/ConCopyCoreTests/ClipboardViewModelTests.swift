import AppKit
import GRDB
import XCTest

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

        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Hello Direct Paste", primaryType: .text))
        vm.loadClips()
        await vm.waitForPendingLoads()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip)
        await vm.waitForPendingLoads()

        XCTAssertEqual(vm.selectedClipId, clip.id)
        XCTAssertTrue(vm.selectedClipIds.isEmpty)
        XCTAssertTrue(panelClosed, "Panel must close when isDirectPasteEnabled is true")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1, "Must inject Command+V paste event")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Hello Direct Paste")
    }

    func testSingleClickWithDirectPasteDisabledCopiesAndClosesPanel() async throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        settings.isDirectPasteEnabled = false
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Copy Only Mode", primaryType: .text))
        vm.loadClips()
        await vm.waitForPendingLoads()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip)
        await vm.waitForPendingLoads()

        XCTAssertEqual(vm.selectedClipId, clip.id)
        XCTAssertTrue(vm.selectedClipIds.isEmpty)
        XCTAssertTrue(panelClosed, "Panel must close after copying when isDirectPasteEnabled is false")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0, "Must not inject paste command")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Copy Only Mode")
    }

    func testSingleClickUsesClickedRecordAndClosesAfterPreparingClipboard() async throws {
        for directPaste in [false, true] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClickTarget_\(UUID())"))
            let settings = AppSettingsManager(userDefaults: defaults)
            settings.isDirectPasteEnabled = directPaste
            let board = NSPasteboard.withUniqueName()
            let poster = MockCGEventPoster()
            poster.observedPasteboard = board
            let vm = ClipboardViewModel(
                databaseManager: databaseManager, pasteInjector: PasteInjector(eventPoster: poster),
                appSettings: settings, pasteboard: board
            )
            _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Previously selected \(directPaste)"))
            _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Clicked record \(directPaste)"))
            vm.loadClips()
            await vm.waitForPendingLoads()
            let clicked = try XCTUnwrap(vm.clips.last)
            vm.selectedIndex = 0
            XCTAssertNotEqual(vm.selectedClipId, clicked.id)
            vm.selectedClipIds = Set(vm.clips.map(\.id))

            var closeCount = 0
            vm.onClosePanel = {
                closeCount += 1
                XCTAssertEqual(board.string(forType: .string), clicked.plainText, "Prepare the clicked record before closing")
                XCTAssertEqual(board.string(forType: PasteInjector.internalPasteMarker), "1")
                XCTAssertEqual(poster.postCommandVCalledCount, 0, "Restore focus before injecting the paste command")
            }

            vm.handleRowClick(clip: clicked)
            await vm.waitForPendingLoads()

            XCTAssertEqual(closeCount, 1)
            XCTAssertTrue(vm.selectedClipIds.isEmpty)
            XCTAssertEqual(vm.selectedClipId, clicked.id)
            XCTAssertEqual(board.string(forType: .string), clicked.plainText)
            XCTAssertEqual(poster.pastedValues, directPaste ? [clicked.plainText ?? ""] : [])
            XCTAssertEqual(poster.postCommandVCalledCount, directPaste ? 1 : 0)
            XCTAssertNil(vm.pastingClipId)
        }
    }

    func testOptionClickKeepsPlainTextOverrideAndClosesPanelInBothModes() async throws {
        let clip = try databaseManager.ingestCapturedClip(CapturedClip(
            plainText: "Formatted clip", primaryType: .richText,
            representations: ["public.rtf": Data("{\\rtf1 Formatted clip}".utf8)]
        ))
        for directPaste in [false, true] {
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "OptionClick_\(UUID())"))
            let settings = AppSettingsManager(userDefaults: defaults)
            settings.isDirectPasteEnabled = directPaste
            let board = NSPasteboard.withUniqueName()
            let poster = MockCGEventPoster()
            let vm = ClipboardViewModel(
                databaseManager: databaseManager, pasteInjector: PasteInjector(eventPoster: poster),
                appSettings: settings, pasteboard: board
            )
            await vm.waitForPendingLoads()
            var panelClosed = false
            vm.onClosePanel = { panelClosed = true }

            vm.handleRowClick(clip: clip, modifiers: [.option])
            await vm.waitForPendingLoads()

            XCTAssertTrue(panelClosed)
            XCTAssertEqual(board.string(forType: .string), "Formatted clip")
            XCTAssertNil(board.data(forType: .rtf))
            XCTAssertEqual(poster.postCommandVCalledCount, directPaste ? 1 : 0)
        }
    }

    func testRepeatedCopyOfSameClipRestartsFeedbackDuration() async throws {
        let vm = try makeCopyOnlyViewModel()
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Repeated copy", primaryType: .text)
        )
        vm.loadClips()
        await vm.waitForPendingLoads()

        vm.copyClipToPasteboardWithoutClosing(clip: clip)
        await vm.waitForPendingLoads()
        try await Task.sleep(nanoseconds: 700_000_000)
        vm.copyClipToPasteboardWithoutClosing(clip: clip)
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.copiedClipId, clip.id)

        // The original deadline has elapsed, but the latest copy is still within 1.2 seconds.
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(vm.copiedClipId, clip.id, "An earlier copy must not clear the latest feedback")

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(vm.copiedClipId, "Feedback must clear after the latest copy's deadline")
    }

    func testCopyingDifferentClipRestartsFeedbackDuration() async throws {
        let vm = try makeCopyOnlyViewModel()
        let firstClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "First copy", primaryType: .text)
        )
        let secondClip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Second copy", primaryType: .text)
        )
        vm.loadClips()
        await vm.waitForPendingLoads()

        vm.copyClipToPasteboardWithoutClosing(clip: firstClip)
        await vm.waitForPendingLoads()
        try await Task.sleep(nanoseconds: 700_000_000)
        vm.copyClipToPasteboardWithoutClosing(clip: secondClip)
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.copiedClipId, secondClip.id)

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(vm.copiedClipId, secondClip.id, "Canceling the previous timer must preserve the latest feedback")

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(vm.copiedClipId, "Feedback must clear after the latest copy's deadline")
    }

    func testShiftClickUpdatesSelectedClipIdsWithoutCopyOrClosing() async throws {
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
        await vm.waitForPendingLoads()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        NSPasteboard.general.clearContents()

        let targetClip = vm.clips[2]
        vm.handleRowClick(clip: targetClip, shiftHeld: true)
        await vm.waitForPendingLoads()

        XCTAssertFalse(panelClosed, "Shift+Click must not close panel")
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0, "Shift+Click must not paste")
        XCTAssertNil(vm.copiedClipId, "Shift+Click must not trigger copied state")
        XCTAssertEqual(vm.selectedClipIds.count, 3, "Range [0...2] should contain 3 items")
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[0].id))
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[1].id))
        XCTAssertTrue(vm.selectedClipIds.contains(vm.clips[2].id))
        XCTAssertEqual(vm.selectedClipId, targetClip.id)
    }

    func testShiftClickWhenNoInitialSelectionSelectsSingleRecord() async throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "A", primaryType: .text))
        let _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "B", primaryType: .text))
        vm.loadClips()
        await vm.waitForPendingLoads()

        vm.selectedIndex = -1
        XCTAssertNil(vm.selectedClipId)

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip1, shiftHeld: true)
        await vm.waitForPendingLoads()

        XCTAssertFalse(panelClosed)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)
        XCTAssertNil(vm.copiedClipId)
        XCTAssertEqual(vm.selectedClipIds, [clip1.id])
        XCTAssertEqual(vm.selectedClipId, clip1.id)
    }

    func testCommandClickTogglesSelectionWithoutCopyOrClosing() async throws {
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "Test_\(UUID().uuidString)")!)
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let vm = ClipboardViewModel(databaseManager: databaseManager, pasteInjector: injector, appSettings: settings)

        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "A", primaryType: .text))
        let _ = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "B", primaryType: .text))
        vm.loadClips()
        await vm.waitForPendingLoads()

        var panelClosed = false
        vm.onClosePanel = { panelClosed = true }

        vm.handleRowClick(clip: clip1, commandHeld: true)
        await vm.waitForPendingLoads()
        XCTAssertFalse(panelClosed)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)
        XCTAssertTrue(vm.selectedClipIds.contains(clip1.id))

        vm.handleRowClick(clip: clip1, commandHeld: true)
        await vm.waitForPendingLoads()
        XCTAssertFalse(panelClosed)
        XCTAssertFalse(vm.selectedClipIds.contains(clip1.id))
    }

    private func makeCopyOnlyViewModel() throws -> ClipboardViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Test_\(UUID().uuidString)"))
        let settings = AppSettingsManager(userDefaults: defaults)
        settings.isDirectPasteEnabled = false
        return ClipboardViewModel(
            databaseManager: databaseManager,
            pasteInjector: PasteInjector(eventPoster: MockCGEventPoster()),
            appSettings: settings
        )
    }
}

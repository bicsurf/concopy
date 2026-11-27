import AppKit
import GRDB
import XCTest

@testable import ConCopyCore
@testable import ConCopyUI

@MainActor
final class AuditUIAndLifecycleTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopyUIAudit_\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    private func database() throws -> DatabaseManager {
        try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent("blobs"))
    }
    private func settings() throws -> AppSettingsManager {
        AppSettingsManager(userDefaults: try XCTUnwrap(UserDefaults(suiteName: "ConCopy.Audit.\(UUID())")))
    }
    nonisolated private static func waitForSemaphore(_ semaphore: DispatchSemaphore) {
        _ = semaphore.wait(timeout: .now() + 2)
    }
    func testA17A32MultipleFilesRoundTripAndResolveFromPayload() async throws {
        let db = try database()
        let pasteboard = NSPasteboard.withUniqueName()
        let urls = [directory.appendingPathComponent("first.txt"), directory.appendingPathComponent("second.txt")]
        for url in urls { try Data("file".utf8).write(to: url) }
        pasteboard.writeObjects(urls.map { $0 as NSURL })
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard, captureInitialState: true, settingsManager: try settings())
        let captured = try XCTUnwrap(monitor.captureCurrentClip())
        let clip = try db.ingestCapturedClip(captured)
        XCTAssertEqual(try db.fileURLs(for: clip.id), urls)
        try await PasteInjector().copyToPasteboard(clip: clip, databaseManager: db, pasteboard: pasteboard)
        let restored =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(restored, urls)
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
    }
    func testA23PaginationReachesEveryClipWithoutDuplicates() async throws {
        let db = try database()
        for i in 0..<225 { _ = try db.ingestCapturedClip(CapturedClip(plainText: "item \(i)")) }
        let vm = ClipboardViewModel(databaseManager: db, appSettings: try settings())
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 100)
        XCTAssertTrue(vm.hasMoreClips)
        vm.loadNextPage()
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 200)
        XCTAssertTrue(vm.hasMoreClips)
        vm.loadNextPage()
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.count, 225)
        XCTAssertFalse(vm.hasMoreClips)
        XCTAssertEqual(Set(vm.clips.map(\.id)).count, 225)
    }
    func testA24OptionReturnAndNumpadEnterRespectPasteRemapping() throws {
        let manager = GlobalShortcutsManager.shared
        let previous = manager.shortcut(for: .pasteSelection)
        defer { manager.setShortcut(previous, for: .pasteSelection) }
        manager.resetShortcut(for: .pasteSelection)
        for code: UInt16 in [36, 76] {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code))
            XCTAssertTrue(manager.matches(event: event, for: .pasteSelection))
        }
        manager.removeShortcut(for: .pasteSelection)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0, windowNumber: 0, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertFalse(manager.matches(event: event, for: .pasteSelection))
    }
    func testA26ScreenshotPolicyRespectsPauseAndExclusion() throws {
        let settings = try settings()
        settings.autoCaptureScreenshots = true
        settings.isMonitoringPaused = false
        XCTAssertTrue(settings.shouldCaptureScreenshots)
        settings.isMonitoringPaused = true
        XCTAssertFalse(settings.shouldCaptureScreenshots)
        settings.isMonitoringPaused = false
        settings.addExcludedApp(bundleId: ScreenshotWatcher.screenshotBundleId)
        XCTAssertFalse(settings.shouldCaptureScreenshots)
        let watcher = ScreenshotWatcher(monitoredDirectoryURL: directory)
        watcher.isCaptureEnabled = false
        let captures = AuditCounter()
        watcher.onScreenshotCaptured = { _, _ in captures.increment() }
        watcher.checkForNewScreenshots()
        XCTAssertEqual(captures.value, 0)
    }
    func testA27BlockedDatabaseDoesNotBlockSearchOnMainActor() async throws {
        let db = try database()
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try db.dbWriter.write { _ in
                ready.signal()
                _ = release.wait(timeout: .now() + 2)
            }
        }
        await Task.detached { Self.waitForSemaphore(ready) }.value
        let start = Date()
        let vm = ClipboardViewModel(databaseManager: db, appSettings: try settings())
        vm.searchQuery = "first"
        vm.searchQuery = "latest"
        let elapsed = Date().timeIntervalSince(start)
        release.signal()
        try await writer.value
        await vm.waitForPendingLoads()
        XCTAssertLessThan(elapsed, 0.25)
        XCTAssertEqual(vm.searchQuery, "latest")
    }
    func testA28RetentionPolicyCanRunRepeatedlyAndPreservesProtectedClips() throws {
        let db = try database()
        let favorite = try db.ingestCapturedClip(CapturedClip(plainText: "favorite"))
        _ = try db.toggleFavorite(clipId: favorite.id)
        let policy = HistoryRetentionPolicy(enabled: true, days: 30, maxCount: 2)
        for i in 0..<4 {
            _ = try db.ingestCapturedClip(CapturedClip(plainText: "entry \(i)"))
            _ = try policy.apply(to: db)
        }
        XCTAssertEqual(try db.searchClips(limit: 1000).count, 3)
        XCTAssertNotNil(try db.fetchClip(id: favorite.id))
        let disabled = HistoryRetentionPolicy(enabled: false, days: 30, maxCount: 1)
        XCTAssertEqual(try disabled.apply(to: db), 0)
    }
    func testA29SearchReconcilesSelectionWithVisibleBatch() async throws {
        let db = try database()
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "alpha"))
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "beta"))
        let vm = ClipboardViewModel(databaseManager: db, appSettings: try settings())
        await vm.waitForPendingLoads()
        vm.selectedClipIds = Set(vm.clips.map(\.id))
        vm.searchQuery = "alpha"
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.selectedClipIds.count, 1)
        XCTAssertEqual(vm.selectedClipIds, Set(vm.clips.map(\.id)))
    }
    func testA30RemainsUnchangedAndA31PanelIsNonactivating() throws {
        let manager = GlobalShortcutsManager.shared
        let swapped = manager.swapNumericModifiers
        defer { manager.setSwapNumericModifiers(swapped) }
        manager.setSwapNumericModifiers(false)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: 0, context: nil,
                characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertTrue(manager.matchesAllClips(event: event), "A30 is intentionally preserved")
        let panel = FloatingPanel(
            viewModel: ClipboardViewModel(databaseManager: try database(), appSettings: try settings()))
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.canBecomeKey)
        panel.orderOut(nil)
    }
    func testA35ExportedFilesWithSameLabelAreIndependent() throws {
        let exporter = FilePasteExporter(exportDirectoryURL: directory)
        let a = try exporter.exportTextAsFile("first", preferredName: "same")
        let b = try exporter.exportTextAsFile("second", preferredName: "same")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try String(contentsOf: a, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: b, encoding: .utf8), "second")
    }
    func testA38SnippetConflictReturnsFailureAndKeepsEditorState() async throws {
        let vm = ClipboardViewModel(databaseManager: try database(), appSettings: try settings())
        let success = await vm.saveSnippet(shortcut: ";same", content: "original")
        XCTAssertTrue(success)
        let draft = SnippetRecord(shortcut: ";same", content: "unsaved work")
        vm.editingSnippet = draft
        vm.isSnippetEditorPresented = true
        let conflict = await vm.saveSnippet(shortcut: ";same", content: draft.content, existingId: draft.id)
        XCTAssertFalse(conflict)
        XCTAssertNotNil(vm.snippetSaveError)
        XCTAssertTrue(vm.isSnippetEditorPresented)
        XCTAssertEqual(vm.editingSnippet?.content, "unsaved work")
    }

    func testQuickActionEligibility() {
        let textClip = ClipRecord(
            contentHash: "hash1",
            plainText: "echo hello",
            primaryType: .text
        )
        XCTAssertTrue(QuickActionRunner.canExecute(.terminal, for: textClip))
        XCTAssertTrue(QuickActionRunner.canExecute(.runShellScript, for: textClip))
        XCTAssertTrue(QuickActionRunner.canExecute(.openInTextEdit, for: textClip))
        XCTAssertFalse(QuickActionRunner.canExecute(.openInBrowser, for: textClip))

        let urlClip = ClipRecord(
            contentHash: "hash2",
            plainText: "https://apple.com",
            primaryType: .url
        )
        XCTAssertTrue(QuickActionRunner.canExecute(.openInBrowser, for: urlClip))

        let emptyClip = ClipRecord(
            contentHash: "hash3",
            plainText: "   ",
            primaryType: .text
        )
        XCTAssertFalse(QuickActionRunner.canExecute(.terminal, for: emptyClip))
    }

    func testQuickActionShellScriptLargeOutputDoesNotDeadlock() async {
        let exp = expectation(description: "Shell command completes")
        // Generates ~100KB of text, exceeding the standard 64KB OS pipe buffer
        let script = "head -c 100000 /dev/zero | tr '\\0' 'A'"
        QuickActionRunner.execute(.runShellScript, text: script, skipConfirmation: true) { result in
            XCTAssertNotNil(result)
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 5.0)
    }

    func testClipRowViewEquatableIncludesAppIconImage() {
        let clip = ClipRecord(contentHash: "h", plainText: "t", primaryType: .text)
        let icon1 = NSImage(size: NSSize(width: 16, height: 16))
        let icon2 = NSImage(size: NSSize(width: 16, height: 16))
        let row1 = ClipRowView(
            clip: clip, index: 0, isSelected: false, isChecked: false, isPasting: false,
            shortcutLabel: nil, appIconImage: icon1, onToggleCheck: {}
        )
        let row2 = ClipRowView(
            clip: clip, index: 0, isSelected: false, isChecked: false, isPasting: false,
            shortcutLabel: nil, appIconImage: icon2, onToggleCheck: {}
        )
        let row1Duplicate = ClipRowView(
            clip: clip, index: 0, isSelected: false, isChecked: false, isPasting: false,
            shortcutLabel: nil, appIconImage: icon1, onToggleCheck: {}
        )
        XCTAssertEqual(row1, row1Duplicate)
        XCTAssertNotEqual(row1, row2)
    }

    func testFilePasteExporterErrorEnglishDescriptions() {
        XCTAssertEqual(
            FilePasteExporterError.invalidImageData.localizedDescription,
            "Invalid image data or unsupported format."
        )
        XCTAssertEqual(
            FilePasteExporterError.imageConversionFailed.localizedDescription,
            "Unable to convert image to specified format."
        )
    }

    func testFloatingPanelPositionNearCaretSafelyHandlesNonConformingAX() throws {
        let panel = FloatingPanel(
            viewModel: ClipboardViewModel(databaseManager: try database(), appSettings: try settings()))
        let originalFrame = panel.frame
        XCTAssertFalse(panel.positionNearCaret(focusedElementValue: nil))
        XCTAssertFalse(panel.positionNearCaret(focusedElementValue: "Invalid AX element" as NSString))
        XCTAssertEqual(panel.frame, originalFrame)
    }

    func testSensitiveDataDetectorAWSAndSSHKeyDetection() {
        XCTAssertTrue(SensitiveDataDetector.isSensitive("AKIAIOSFODNN7EXAMPLE"))
        XCTAssertTrue(SensitiveDataDetector.isSensitive("-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0..."))
        XCTAssertTrue(SensitiveDataDetector.isSensitive("4532 1123 4567 8910"))
        XCTAssertTrue(SensitiveDataDetector.isSensitive("Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"))
        XCTAssertEqual(
            SensitiveDataDetector.maskSensitiveText("4532 1123 4567 8910"),
            "4532 •••• •••• 8910"
        )
        XCTAssertFalse(SensitiveDataDetector.isSensitive("Ordinary clipboard message"))
    }
}

private final class AuditCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

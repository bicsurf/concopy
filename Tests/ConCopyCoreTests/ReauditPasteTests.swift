import AppKit
import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

private final class FocusSwitchPoster: CGEventPosting, @unchecked Sendable {
    private let lock = NSLock()
    private var processID: pid_t = 100
    private var sent: [String] = []
    var events: [String] { lock.withLock { sent } }
    var pid: pid_t { lock.withLock { processID } }
    func isProcessTrusted() -> Bool { true }
    func postCommandV() -> Bool {
        lock.withLock { sent.append("paste"); processID = 200 }
        return true
    }
    func postTab() -> Bool {
        lock.withLock { sent.append("tab") }
        return true
    }
}

private struct FailingEventPoster: CGEventPosting {
    func isProcessTrusted() -> Bool { true }
    func postCommandV() -> Bool { false }
    func postTab() -> Bool { false }
}

@MainActor
final class ReauditPasteTests: XCTestCase {
    func testB17QuickPasteConsumesItsModifierAndPreservesAllFormats() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B17-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let url = URL(fileURLWithPath: "/tmp/document.txt")
        let captures = [CapturedClip(plainText: "image", primaryType: .image, representations: ["public.png": Data([1,2,3])]),
            CapturedClip(plainText: "document.txt", primaryType: .file, representations: ["public.file-url": Data(url.absoluteString.utf8)]),
            CapturedClip(plainText: "rich", primaryType: .richText, representations: ["public.rtf": Data("{\\rtf1 rich}".utf8)])]
        let manager = GlobalShortcutsManager.shared, original = manager.swapNumericModifiers
        defer { manager.setSwapNumericModifiers(original) }
        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            let flags: NSEvent.ModifierFlags = swapped ? [.command] : [.command, .option]
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: "1", charactersIgnoringModifiers: "1", isARepeat: false, keyCode: 18))
            XCTAssertEqual(manager.matchedQuickPasteIndex(for: event), 0)
            XCTAssertFalse(manager.plainTextOverride(for: event))
            for capture in captures {
                let clip = try db.ingestCapturedClip(capture), board = NSPasteboard.withUniqueName()
                try await PasteInjector().copyToPasteboard(clip: clip, databaseManager: db, pasteboard: board,
                    forcePlainText: manager.plainTextOverride(for: event))
                switch capture.primaryType {
                case .image: XCTAssertEqual(board.data(forType: .png), capture.representations["public.png"])
                case .richText: XCTAssertEqual(board.data(forType: .rtf), capture.representations["public.rtf"])
                case .file:
                    XCTAssertEqual(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], [url])
                default: XCTFail("Unexpected fixture")
                }
            }
        }
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(manager.plainTextOverride(for: plain), "Option+Return must still request plain text")
    }
    func testB18AllPastePathsReportEventFailureWithoutCountingSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B18-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let injector = PasteInjector(eventPoster: FailingEventPoster(), fileExporter: FilePasteExporter(exportDirectoryURL: directory))
        let board = NSPasteboard.withUniqueName()
        for mode in 0..<3 {
            let clip = try db.ingestCapturedClip(CapturedClip(plainText: "case \(mode)"))
            do {
                switch mode {
                case 0: try await injector.paste(clip: clip, databaseManager: db, pasteboard: board)
                case 1: try await injector.pasteAsFile(clip: clip, databaseManager: db, pasteboard: board)
                default: try await injector.pasteBatch(clips: [clip], mode: .concatenated(separator: .newline), databaseManager: db, pasteboard: board)
                }
                XCTFail("Failed CGEvent posting must be reported")
            } catch { XCTAssertTrue(error is PasteInjectionError) }
            XCTAssertEqual(try db.fetchClip(id: clip.id)?.pasteCount, 0)
            XCTAssertNotNil(board.data(forType: PasteInjector.internalPasteMarker))
        }
    }
    func testB04ActionsCannotUseThePreviousSearchSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B04-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let alpha = try db.ingestCapturedClip(CapturedClip(plainText: "alpha"))
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "beta"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "B04-\(UUID())"))
        let vm = ClipboardViewModel(databaseManager: db, appSettings: AppSettingsManager(userDefaults: defaults))
        await vm.waitForPendingLoads()
        vm.searchQuery = "alpha"
        XCTAssertTrue(vm.isLoadingClips)
        vm.pasteSelected()
        vm.paste(at: 0)
        vm.pasteSelectedBatch(mode: .concatenated(separator: .newline))
        XCTAssertNil(vm.pastingClipId)
        await vm.waitForPendingLoads()
        XCTAssertEqual(vm.clips.map(\.id), [alpha.id])
        XCTAssertEqual(try db.fetchClip(id: alpha.id)?.pasteCount, 0)
    }
    func testB19FocusChangeAfterPasteDoesNotSendTab() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("B19-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let clips = try ["first", "second"].map { try db.ingestCapturedClip(CapturedClip(plainText: $0)) }
        let poster = FocusSwitchPoster()
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        do {
            try await injector.pasteBatch(
                clips: clips, mode: .sequentialFormFields(delayMs: 0), databaseManager: db,
                pasteboard: .withUniqueName())
            XCTFail("A context change must cancel the remaining batch")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .userCancelled)
        }
        XCTAssertEqual(poster.events, ["paste"], "Tab must never reach the newly focused application")
    }
}

import AppKit
import GRDB
import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

private final class InitialFocusEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var process: pid_t = 100
    private var sent: [String] = []
    var pid: pid_t { lock.withLock { process } }
    var events: [String] { lock.withLock { sent } }
    func switchApp() { lock.withLock { process = 200 } }
    func record(_ value: String) { lock.withLock { sent.append(value) } }
}
private struct InitialFocusPoster: CGEventPosting {
    let environment: InitialFocusEnvironment
    func isProcessTrusted() -> Bool { true }
    func postCommandV() -> Bool { environment.record("paste"); return true }
    func postTab() -> Bool { environment.record("tab"); return true }
}
private struct ThirdEventPoster: CGEventPosting {
    let trusted: Bool
    let succeeds: Bool
    func isProcessTrusted() -> Bool { trusted }
    func postCommandV() -> Bool { succeeds }
    func postTab() -> Bool { succeeds }
}

@MainActor
final class ThirdAuditPasteTests: XCTestCase {
    private func rejectUsage(_ db: DatabaseManager) throws {
        try db.dbWriter.write { sql in
            try sql.execute(sql: "CREATE TRIGGER reject_usage BEFORE INSERT ON sync_usage BEGIN SELECT RAISE(ABORT,'test statistics failure'); END")
        }
    }
    func testC08StatisticsFailureDoesNotTurnSuccessfulTransferIntoPasteFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdStats-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let clips = try ["first", "second"].map { try db.ingestCapturedClip(CapturedClip(plainText: $0)) }
        try rejectUsage(db)
        let environment = InitialFocusEnvironment()
        let injector = PasteInjector(eventPoster: InitialFocusPoster(environment: environment),
            fileExporter: FilePasteExporter(exportDirectoryURL: directory), frontmostProcessIdentifier: { environment.pid })
        let board = NSPasteboard.withUniqueName()
        let results = [
            try await injector.paste(clip: clips[0], databaseManager: db, pasteboard: board),
            try await injector.pasteAsFile(clip: clips[0], databaseManager: db, pasteboard: board),
            try await injector.pasteBatch(clips: clips, mode: .concatenated(separator: .newline), databaseManager: db, pasteboard: board),
            try await injector.pasteBatch(clips: clips, mode: .sequentialFormFields(delayMs: 0), databaseManager: db, pasteboard: board),
        ]
        XCTAssertTrue(results.allSatisfy { $0.eventSent && !$0.usageRecorded })
        XCTAssertEqual(environment.events, ["paste", "paste", "paste", "paste", "tab", "paste"])
        XCTAssertEqual(try db.fetchClip(id: clips[0].id)?.pasteCount, 0)
        let copied = try await injector.copyToPasteboard(clip: clips[0], databaseManager: db, pasteboard: board)
        XCTAssertFalse(copied.eventSent); XCTAssertFalse(copied.usageRecorded)
        XCTAssertEqual(board.string(forType: .string), "first")
    }
    func testC08ViewModelDoesNotReopenPanelWhenOnlyStatisticsFail() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdStatsUI-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "already pasted"))
        try rejectUsage(db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ThirdStats-\(UUID())"))
        let board = NSPasteboard.withUniqueName()
        let vm = ClipboardViewModel(databaseManager: db,
            pasteInjector: PasteInjector(eventPoster: ThirdEventPoster(trusted: true, succeeds: true)),
            appSettings: AppSettingsManager(userDefaults: defaults), pasteboard: board)
        await vm.waitForPendingLoads()
        var failures = 0
        vm.onPasteFailure = { failures += 1 }
        vm.pasteSelected()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(board.string(forType: .string), "already pasted")
    }
    func testC09SnippetEventFailureIsReportedAndManualCopyRemainsAvailable() async throws {
        for trusted in [true, false] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdSnippet-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: "ThirdSnippet-\(UUID())"))
            let board = NSPasteboard.withUniqueName()
            let vm = ClipboardViewModel(databaseManager: db,
                pasteInjector: PasteInjector(eventPoster: ThirdEventPoster(trusted: trusted, succeeds: false)),
                appSettings: AppSettingsManager(userDefaults: defaults), pasteboard: board)
            var failures = 0
            vm.onPasteFailure = { failures += 1 }
            vm.pasteSnippet(SnippetRecord(shortcut: ";hello", content: "snippet"))
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(failures, trusted ? 1 : 0)
            XCTAssertEqual(board.string(forType: .string), "snippet")
            XCTAssertEqual(board.string(forType: PasteInjector.internalPasteMarker), "1")
            XCTAssertNotNil(vm.toastMessage)
            if !trusted { XCTAssertTrue(vm.toastMessage?.contains("⌘V") == true) }
        }
    }
    func testC07InitialContextSwitchCancelsBeforeAnyEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ThirdPaste-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory)
        let clips = try ["first", "second"].map { try db.ingestCapturedClip(CapturedClip(plainText: $0)) }
        let environment = InitialFocusEnvironment()
        let injector = PasteInjector(eventPoster: InitialFocusPoster(environment: environment),
            frontmostProcessIdentifier: { environment.pid })
        do {
            try await injector.pasteBatch(clips: clips, mode: .sequentialFormFields(delayMs: 0),
                databaseManager: db, pasteboard: .withUniqueName(), beforeEventHook: { environment.switchApp() })
            XCTFail("A changed destination must cancel the batch")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .userCancelled) }
        XCTAssertEqual(environment.events, [])
        XCTAssertEqual(try db.fetchClip(id: clips[0].id)?.pasteCount, 0)
    }
}

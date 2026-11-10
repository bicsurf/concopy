import AppKit
import XCTest
@testable import ConCopyCore

final class MockCGEventPoster: CGEventPosting, @unchecked Sendable {
    var postCommandVCalledCount = 0
    var postTabCalledCount = 0
    var trusted = true

    func isProcessTrusted() -> Bool {
        trusted
    }

    func postCommandV() -> Bool {
        guard isProcessTrusted() else { return false }
        postCommandVCalledCount += 1
        return true
    }

    func postTab() -> Bool {
        guard isProcessTrusted() else { return false }
        postTabCalledCount += 1
        return true
    }
}

final class PasteInjectorTests: XCTestCase {
    private var tempBlobDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempBlobDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyPasteTests_\(UUID().uuidString)")
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

    func testMultiFormatRestore() throws {
        let rtfData = Data("{\\rtf1 Rich text sample}".utf8)
        let captured = CapturedClip(
            plainText: "Rich text sample",
            primaryType: .richText,
            sourceAppBundleId: "com.apple.TextEdit",
            representations: [
                "public.utf8-plain-text": Data("Rich text sample".utf8),
                "public.rtf": rtfData
            ]
        )

        let clip = try databaseManager.ingestCapturedClip(captured)
        let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
        let pasteboard = NSPasteboard.withUniqueName()
        let injector = PasteInjector()

        try injector.preparePasteboard(
            for: clip,
            payloads: payloads,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            forcePlainText: false
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "Rich text sample")
        XCTAssertEqual(pasteboard.data(forType: NSPasteboard.PasteboardType("public.rtf")), rtfData)
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
    }

    func testForcePlainTextMode() throws {
        let rtfData = Data("{\\rtf1 Rich text sample}".utf8)
        let htmlData = Data("<p>Rich text sample</p>".utf8)
        let captured = CapturedClip(
            plainText: "Rich text sample",
            primaryType: .richText,
            representations: [
                "public.utf8-plain-text": Data("Rich text sample".utf8),
                "public.rtf": rtfData,
                "public.html": htmlData
            ]
        )

        let clip = try databaseManager.ingestCapturedClip(captured)
        let payloads = try databaseManager.fetchPayloads(forClipId: clip.id)
        let pasteboard = NSPasteboard.withUniqueName()
        let injector = PasteInjector()

        try injector.preparePasteboard(
            for: clip,
            payloads: payloads,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            forcePlainText: true
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "Rich text sample")
        XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("public.rtf")))
        XCTAssertNil(pasteboard.data(forType: NSPasteboard.PasteboardType("public.html")))
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
    }

    @MainActor
    func testLoopPreventionOnClipboardMonitor() {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardMonitor(pasteboard: pasteboard)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("Injected internal content", forType: .string)
        item.setData(Data(), forType: PasteInjector.internalPasteMarker)
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let captured = monitor.checkForChanges()
        XCTAssertNil(captured, "Pasteboard items with internalPaste marker must be ignored by monitor")
    }

    @MainActor
    func testLoopPreventionDuringPasteExecution() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        let captured = CapturedClip(plainText: "Existing clip to paste without loop")
        let clip = try databaseManager.ingestCapturedClip(captured)

        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)

        try await injector.paste(
            clip: clip,
            databaseManager: databaseManager,
            pasteboard: pasteboard
        )

        // Verify monitor ignores the pasteboard write because of internalPasteMarker
        let item = monitor.checkForChanges()
        XCTAssertNil(item, "ClipboardMonitor must ignore internal paste and not create duplicate or loop")
    }

    @MainActor
    func testPasteCountIncrementAndMockCGEvent() async throws {
        let captured = CapturedClip(plainText: "Item to paste")
        let clip = try databaseManager.ingestCapturedClip(captured)
        XCTAssertEqual(clip.pasteCount, 0)

        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        var hookCalled = false
        try await injector.paste(
            clip: clip,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            beforeEventHook: {
                hookCalled = true
            }
        )

        XCTAssertTrue(hookCalled)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1)

        let updated = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(updated?.pasteCount, 1)
    }

    @MainActor
    func testBatchPasteFallbackWhenAccessibilityNotTrusted() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Alpha"))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Beta"))

        let untrustedPoster = MockCGEventPoster()
        untrustedPoster.trusted = false
        let injector = PasteInjector(eventPoster: untrustedPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        try await injector.pasteBatch(
            clips: [clip1, clip2],
            mode: .concatenated(separator: .tab),
            transformation: .none,
            databaseManager: databaseManager,
            pasteboard: pasteboard
        )

        // Clipboard was still populated despite accessibility being untrusted
        XCTAssertEqual(pasteboard.string(forType: .string), "Alpha\tBeta")
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
        XCTAssertEqual(untrustedPoster.postCommandVCalledCount, 0, "No CGEvent should be posted when untrusted")
    }

    @MainActor
    func testCopyToPasteboardWithoutCommandV() throws {
        let clip = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Copy without auto-paste"))
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        try injector.copyToPasteboard(
            clip: clip,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            forcePlainText: false,
            transformation: .none
        )

        // Clipboard is populated with internal marker and string
        XCTAssertEqual(pasteboard.string(forType: .string), "Copy without auto-paste")
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
        // No CGEvent synthesized
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)

        // Paste count incremented
        let updated = try databaseManager.fetchClip(id: clip.id)
        XCTAssertEqual(updated?.pasteCount, 1)
    }

    @MainActor
    func testCopyBatchToPasteboardWithoutCommandV() throws {
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "First"))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Second"))
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        try injector.copyBatchToPasteboard(
            clips: [clip1, clip2],
            mode: .concatenated(separator: .newline),
            transformation: .none,
            databaseManager: databaseManager,
            pasteboard: pasteboard
        )

        XCTAssertEqual(pasteboard.string(forType: .string), "First\nSecond")
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 0)

        let updated1 = try databaseManager.fetchClip(id: clip1.id)
        let updated2 = try databaseManager.fetchClip(id: clip2.id)
        XCTAssertEqual(updated1?.pasteCount, 1)
        XCTAssertEqual(updated2?.pasteCount, 1)
    }

    func testQuickPasteShortcutMapper() {
        // Labels
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 0), "1")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 8), "9")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 9), "0")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 10), "a")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 35), "z")
        XCTAssertNil(QuickPasteShortcutMapper.label(forIndex: 36))
        XCTAssertNil(QuickPasteShortcutMapper.label(forIndex: -1))

        // Index reverse lookup
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "1"), 0)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "9"), 8)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "0"), 9)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "a"), 10)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "A"), 10)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "z"), 35)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "Z"), 35)
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: "36"))
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: "!"))
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: ""))
    }
}

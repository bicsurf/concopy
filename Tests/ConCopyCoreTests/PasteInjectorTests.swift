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
        postCommandVCalledCount += 1
        return true
    }

    func postTab() -> Bool {
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

    func testQuickPasteShortcutMapper() {
        // Labels
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 0), "0")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 9), "9")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 10), "a")
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 35), "z")
        XCTAssertNil(QuickPasteShortcutMapper.label(forIndex: 36))
        XCTAssertNil(QuickPasteShortcutMapper.label(forIndex: -1))

        // Index reverse lookup
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "0"), 0)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "9"), 9)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "a"), 10)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "A"), 10)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "z"), 35)
        XCTAssertEqual(QuickPasteShortcutMapper.index(forCharacter: "Z"), 35)
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: "36"))
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: "!"))
        XCTAssertNil(QuickPasteShortcutMapper.index(forCharacter: ""))
    }
}

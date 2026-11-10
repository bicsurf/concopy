import AppKit
import XCTest
@testable import ConCopyCore

final class Phase4Tests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyPhase4Tests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempDir)
    }

    override func tearDownWithError() throws {
        databaseManager = nil
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    func testTextTransformations() {
        XCTAssertEqual(TextTransformer.apply(.none, to: "hello"), "hello")
        XCTAssertEqual(TextTransformer.apply(.uppercase, to: "hello world"), "HELLO WORLD")
        XCTAssertEqual(TextTransformer.apply(.lowercase, to: "HELLO WORLD"), "hello world")
        XCTAssertEqual(TextTransformer.apply(.capitalize, to: "hello world"), "Hello World")
        XCTAssertEqual(TextTransformer.apply(.trimWhitespace, to: "   hello    world   \n\n  "), "hello world")
        XCTAssertEqual(
            TextTransformer.apply(.stripBlankLines, to: "line 1\n\n\nline 2\n   \nline 3"),
            "line 1\nline 2\nline 3"
        )
        XCTAssertEqual(
            TextTransformer.apply(.singleLine, to: "line 1\nline 2\nline 3"),
            "line 1 line 2 line 3"
        )
    }

    func testFileExportAndPasteAsFile() async throws {
        let exporter = FilePasteExporter(exportDirectoryURL: tempDir)

        // 1. Export text as file
        let textFile = try exporter.exportTextAsFile("File export content", preferredName: "NotesFile")
        XCTAssertTrue(FileManager.default.fileExists(atPath: textFile.path))
        XCTAssertTrue(textFile.lastPathComponent.contains("NotesFile"))
        let readText = try String(contentsOf: textFile, encoding: .utf8)
        XCTAssertEqual(readText, "File export content")

        // 2. Export image as PNG and JPEG
        let testImage = try createSampleImageData()
        let pngFile = try exporter.exportImageAsFile(imageData: testImage, format: .png, preferredName: "sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: pngFile.path))
        XCTAssertEqual(pngFile.pathExtension, "png")

        let jpgFile = try exporter.exportImageAsFile(imageData: testImage, format: .jpeg, preferredName: "sample")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpgFile.path))
        XCTAssertEqual(jpgFile.pathExtension, "jpg")

        // 3. Paste as file to NSPasteboard
        let clip = try databaseManager.ingestCapturedClip(
            CapturedClip(plainText: "Export as file clip")
        )
        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster, fileExporter: exporter)
        let pasteboard = NSPasteboard.withUniqueName()

        try await injector.pasteAsFile(
            clip: clip,
            databaseManager: databaseManager,
            pasteboard: pasteboard
        )

        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1)
        XCTAssertNotNil(pasteboard.data(forType: PasteInjector.internalPasteMarker))

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        XCTAssertNotNil(urls)
        XCTAssertEqual(urls?.count, 1)
        if let exportedURL = urls?.first {
            XCTAssertTrue(FileManager.default.fileExists(atPath: exportedURL.path))
        }
    }

    @MainActor
    func testBatchPasteConcatenated() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "first item"))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "second item"))
        let clip3 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "third item"))

        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        try await injector.pasteBatch(
            clips: [clip1, clip2, clip3],
            mode: .concatenated(separator: .newline),
            transformation: .uppercase,
            databaseManager: databaseManager,
            pasteboard: pasteboard
        )

        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1)
        XCTAssertEqual(pasteboard.string(forType: .string), "FIRST ITEM\nSECOND ITEM\nTHIRD ITEM")

        let updated1 = try databaseManager.fetchClip(id: clip1.id)
        let updated2 = try databaseManager.fetchClip(id: clip2.id)
        let updated3 = try databaseManager.fetchClip(id: clip3.id)
        XCTAssertEqual(updated1?.pasteCount, 1)
        XCTAssertEqual(updated2?.pasteCount, 1)
        XCTAssertEqual(updated3?.pasteCount, 1)
    }

    @MainActor
    func testBatchPasteSequentialFormFields() async throws {
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Name"))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Email"))
        let clip3 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "City"))

        let mockPoster = MockCGEventPoster()
        let injector = PasteInjector(eventPoster: mockPoster)
        let pasteboard = NSPasteboard.withUniqueName()

        var hookCalled = false
        try await injector.pasteBatch(
            clips: [clip1, clip2, clip3],
            mode: .sequentialFormFields(delayMs: 1),
            transformation: .none,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            beforeEventHook: {
                hookCalled = true
            }
        )

        XCTAssertTrue(hookCalled)
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 3)
        XCTAssertEqual(mockPoster.postTabCalledCount, 2)
    }

    func testListsOrderingAndAutoStar() throws {
        let list1 = try databaseManager.createList(name: "List 1")
        let list2 = try databaseManager.createList(name: "List 2")

        let allLists = try databaseManager.fetchAllLists()
        XCTAssertEqual(allLists.count, 2)
        XCTAssertEqual(allLists.first?.name, "List 1")

        // Ingest 3 clips
        let clipA = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Clip A"))
        let clipB = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Clip B"))
        let clipC = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Clip C"))

        // Assign to list1
        _ = try databaseManager.assignClip(clipId: clipA.id, toListId: list1.id)
        _ = try databaseManager.assignClip(clipId: clipB.id, toListId: list1.id)
        _ = try databaseManager.assignClip(clipId: clipC.id, toListId: list1.id)

        // Reorder in list: C, A, B
        try databaseManager.reorderClipsInList(listId: list1.id, orderedClipIds: [clipC.id, clipA.id, clipB.id])

        let manualResults = try databaseManager.searchClips(listId: list1.id, sortMode: .manualOrder)
        XCTAssertEqual(manualResults.map(\.id), [clipC.id, clipA.id, clipB.id])

        // Test pasteCount ordering
        _ = try databaseManager.recordPasteUsage(clipId: clipB.id)
        _ = try databaseManager.recordPasteUsage(clipId: clipB.id)
        _ = try databaseManager.recordPasteUsage(clipId: clipA.id)

        let pasteCountResults = try databaseManager.searchClips(listId: list1.id, sortMode: .pasteCountDesc)
        XCTAssertEqual(pasteCountResults.first?.id, clipB.id)

        // Test auto star
        try databaseManager.setAutoStarList(listId: list2.id)
        let newStarred = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Auto Star Clip"))
        XCTAssertTrue(newStarred.isFavorite)
        XCTAssertEqual(newStarred.listId, list2.id)
    }

    private func createSampleImageData() throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 8,
                pixelsHigh: 8,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 8 * 4,
                bitsPerPixel: 32
            )
        )
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}

import AppKit
import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

private final class ThirdScreenshotStore: @unchecked Sendable {
    let db: DatabaseManager
    private let lock = NSLock()
    private var failures = 0
    init(_ db: DatabaseManager) { self.db = db }
    func add(_ clip: CapturedClip) {
        do { try db.ingestCapturedClip(clip) }
        catch { lock.withLock { failures += 1 } }
    }
    var errors: Int { lock.withLock { failures } }
}

final class ThirdAuditImportAndScreenshotTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = directory.appendingPathComponent("ThirdImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func testC10UnicodePayloadLimitsUseBytesBeforeMaterializingContent() throws {
        for schema in ["generic", "native", "native-title", "native-description", "maccy"] {
            try autoreleasepool {
                // 13 Mi Unicode scalars occupy over 50 MiB as UTF-8, although SQLite length(TEXT) is smaller.
                let text = String(repeating: "😀", count: ClipBatchImporter.maxBlobSizeBytes / 4 + 1)
                let path = directory.appendingPathComponent(schema + ".sqlite")
                let source = try DatabaseQueue(path: path.path)
                try source.write { sql in
                    switch schema {
                    case "maccy":
                        try sql.execute(sql: "CREATE TABLE ZHISTORYITEM(Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZHISTORYITEMCONTENT(Z_PK INTEGER PRIMARY KEY, ZHISTORYITEM INTEGER, ZTYPE TEXT, ZVALUE TEXT); INSERT INTO ZHISTORYITEM VALUES (1)")
                        try sql.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT VALUES (1,1,'public.utf8-plain-text',?)", arguments: [text])
                    case "native", "native-title", "native-description":
                        try sql.execute(sql: "CREATE TABLE ZPASTEBOARDCONTENTS(Z_PK INTEGER PRIMARY KEY,ZNAME TEXT,ZDESC TEXT,ZCREATIONDATE REAL,ZAPPLICATION INTEGER,ZITEMSWRAPPER INTEGER,ZLIST INTEGER,ZTRASHDATE REAL); CREATE TABLE ZPASTEBOARDCONTENTSITEMSWRAPPER(Z_PK INTEGER PRIMARY KEY,ZSTRING TEXT)")
                        try sql.execute(sql: "INSERT INTO ZPASTEBOARDCONTENTS(Z_PK,ZNAME,ZDESC,ZITEMSWRAPPER) VALUES (1,?,?,1)", arguments: [schema == "native-title" ? text : "title", schema == "native-description" ? text : "desc"])
                        try sql.execute(sql: "INSERT INTO ZPASTEBOARDCONTENTSITEMSWRAPPER VALUES (1,?)", arguments: [schema == "native" ? text : "body"])
                    default:
                        try sql.execute(sql: "CREATE TABLE clips(id INTEGER PRIMARY KEY, content TEXT)")
                        try sql.execute(sql: "INSERT INTO clips VALUES (1,?)", arguments: [text])
                    }
                }
                let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent(schema + "-blobs"))
                let importer: any ExternalClipboardImporter = schema == "maccy" ? MaccyImporter(sourceURL: path) : CopyEmImporter(sourceURL: path)
                XCTAssertThrowsError(try importer.importClips(into: db, progress: nil), schema)
                XCTAssertTrue(try db.searchClips().isEmpty, schema)
            }
        }
    }
    private func bitmap() throws -> NSBitmapImageRep {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 192, bitsPerPixel: 24))
        if let pixels = image.bitmapData {
            for i in 0..<12288 { pixels[i] = UInt8(truncatingIfNeeded: i &* 71 &+ i / 9) }
        }
        return image
    }
    func testC11PNGHeaderAndIncompletePixelsAreNotCapturedBeforeTheFullFile() throws {
        let png = try XCTUnwrap(bitmap().representation(using: .png, properties: [:]))
        let shots = directory.appendingPathComponent("shots")
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = shots.appendingPathComponent("Screenshot partial.png")
        let watcher = ScreenshotWatcher(monitoredDirectoryURL: shots)
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent("blobs"))
        let store = ThirdScreenshotStore(db)
        watcher.onScreenshotCaptured = { clip, _ in store.add(clip) }
        for length in [33, 50, png.count / 2, png.count - 12] {
            try png.prefix(length).write(to: file)
            XCTAssertNil(watcher.processFile(at: file), "prefix \(length)")
            watcher.checkForNewScreenshots()
            XCTAssertTrue(try db.searchClips().isEmpty)
        }
        try png.write(to: file)
        watcher.checkForNewScreenshots(); watcher.checkForNewScreenshots()
        XCTAssertEqual(store.errors, 0)
        XCTAssertEqual(try db.searchClips().count, 1)
        let clip = try XCTUnwrap(db.searchClips().first)
        let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first { $0.utiType == "public.png" })
        XCTAssertEqual(try db.loadPayloadData(for: payload), png)
    }
    func testC11CompleteJPEGAndTIFFAreConvertedToRealPNG() throws {
        let image = try bitmap()
        let watcher = ScreenshotWatcher(monitoredDirectoryURL: directory)
        for type in [NSBitmapImageRep.FileType.jpeg, .tiff] {
            let file = directory.appendingPathComponent("Screenshot \(type.rawValue).img")
            try XCTUnwrap(image.representation(using: type, properties: [:])).write(to: file)
            let captured = try XCTUnwrap(watcher.processFile(at: file))
            let png = try XCTUnwrap(captured.representations["public.png"])
            XCTAssertTrue(CompleteImageDecoder.isPNG(png))
            XCTAssertNotNil(CompleteImageDecoder.decode(png))
        }
    }
}

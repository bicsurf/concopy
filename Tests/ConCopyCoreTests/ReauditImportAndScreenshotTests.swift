import AppKit
import Foundation
import GRDB
import XCTest
@testable import ConCopyCore

private final class ScreenshotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var captures = 0
    func increment() { lock.withLock { captures += 1 } }
    var value: Int { lock.withLock { captures } }
}

final class ReauditImportAndScreenshotTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReauditImport-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }
    func testB12AllSourceSchemasReportElementsBeyondTheLimit() throws {
        for schema in ["generic", "native", "maccy"] {
            try autoreleasepool {
                let path = directory.appendingPathComponent(schema + ".sqlite")
                let source = try DatabaseQueue(path: path.path)
                try source.write { d in
                    switch schema {
                    case "maccy":
                        try d.execute(sql: "CREATE TABLE ZHISTORYITEM(Z_PK INTEGER PRIMARY KEY); CREATE TABLE ZHISTORYITEMCONTENT(Z_PK INTEGER PRIMARY KEY, ZHISTORYITEM INTEGER, ZTYPE TEXT, ZVALUE BLOB)")
                        try d.execute(sql: "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50001) INSERT INTO ZHISTORYITEM SELECT x FROM n")
                        try d.execute(sql: "INSERT INTO ZHISTORYITEMCONTENT SELECT Z_PK,Z_PK,'public.utf8-plain-text',CAST('clip-'||Z_PK AS BLOB) FROM ZHISTORYITEM")
                    case "native":
                        try d.execute(sql: "CREATE TABLE ZPASTEBOARDCONTENTS(Z_PK INTEGER PRIMARY KEY,ZNAME TEXT,ZDESC TEXT,ZCREATIONDATE REAL,ZAPPLICATION INTEGER,ZITEMSWRAPPER INTEGER,ZLIST INTEGER,ZTRASHDATE REAL); CREATE TABLE ZPASTEBOARDCONTENTSITEMSWRAPPER(Z_PK INTEGER PRIMARY KEY,ZSTRING TEXT)")
                        try d.execute(sql: "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50001) INSERT INTO ZPASTEBOARDCONTENTS(Z_PK,ZITEMSWRAPPER) SELECT x,x FROM n")
                        try d.execute(sql: "INSERT INTO ZPASTEBOARDCONTENTSITEMSWRAPPER SELECT Z_PK,'clip-'||Z_PK FROM ZPASTEBOARDCONTENTS")
                    default:
                        try d.execute(sql: "CREATE TABLE clips(id INTEGER PRIMARY KEY,content TEXT)")
                        try d.execute(sql: "WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<50001) INSERT INTO clips SELECT x,'clip-'||x FROM n")
                    }
                }
                let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: directory.appendingPathComponent(schema + "-blobs"))
                let importer: any ExternalClipboardImporter = schema == "maccy" ? MaccyImporter(sourceURL: path) : CopyEmImporter(sourceURL: path)
                let result = try importer.importClips(into: db, progress: nil)
                XCTAssertEqual(result.importedCount, 50_000, schema)
                XCTAssertEqual(result.errorsCount, 1, schema)
                XCTAssertFalse(result.isSuccess, schema)
                XCTAssertEqual(result.errors.first?.sourceIdentifier, "batch_limit", schema)
            }
        }
    }
    func testB14IncompleteAndRecreatedScreenshotsAreCapturedOnceComplete() throws {
        let watcher = ScreenshotWatcher(monitoredDirectoryURL: directory), count = ScreenshotCounter()
        watcher.onScreenshotCaptured = { _,_ in count.increment() }
        let file = directory.appendingPathComponent("Screenshot retry.png")
        try Data([0]).write(to: file)
        watcher.checkForNewScreenshots()
        XCTAssertEqual(count.value, 0)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
        bitmap.bitmapData?.initialize(repeating: 0, count: 12)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: file)
        watcher.checkForNewScreenshots()
        watcher.checkForNewScreenshots()
        XCTAssertEqual(count.value, 1)
        try FileManager.default.removeItem(at: file)
        watcher.checkForNewScreenshots()
        try bytes.write(to: file)
        watcher.checkForNewScreenshots()
        XCTAssertEqual(count.value, 2)
    }
    func testB14PendingScreenshotIsRetriedAfterItsContentsChange() async throws {
        let watcher = ScreenshotWatcher(monitoredDirectoryURL: directory), count = ScreenshotCounter()
        watcher.onScreenshotCaptured = { _,_ in count.increment() }
        watcher.start()
        defer { watcher.stop() }
        let file = directory.appendingPathComponent("Screenshot slow.png")
        try Data([0]).write(to: file)
        watcher.checkForNewScreenshots()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 6, bitsPerPixel: 24))
        bitmap.bitmapData?.initialize(repeating: 0, count: 12)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: file)
        for _ in 0..<100 {
            if count.value > 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(count.value, 1)
    }
}

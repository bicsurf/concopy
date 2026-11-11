import AppKit
import XCTest
@testable import ConCopyCore

final class EndToEndIntegrationTests: XCTestCase {
    private var tempDir: URL!
    private var databaseManager: DatabaseManager!
    private var mockPoster: MockCGEventPoster!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConCopyE2ETests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        databaseManager = try DatabaseManager(inMemoryWithBlobDirectoryURL: tempDir)
        mockPoster = MockCGEventPoster()
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDownWithError() throws {
        databaseManager = nil
        mockPoster = nil
        if let dir = tempDir, FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.removeItem(at: dir)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Full Lifecycle Test
    @MainActor
    func testFullLifecycleClipboardToDatabaseAndPaste() async throws {
        // Step A: Setup monitor and injector
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: "E2E_\(UUID().uuidString)")!)
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            settingsManager: settings,
            frontmostAppBundleIdProvider: { "com.apple.Safari" }
        )
        let injector = PasteInjector(eventPoster: mockPoster)

        // Step B: Simulate copy in Safari
        pasteboard.clearContents()
        let sourceText = "concopy is blazing fast and lightweight"
        pasteboard.setString(sourceText, forType: .string)

        let captured = try XCTUnwrap(monitor.checkForChanges())
        XCTAssertEqual(captured.content, sourceText)
        XCTAssertEqual(captured.sourceAppBundleID, "com.apple.Safari")
        let capturedClip = try XCTUnwrap(captured.capturedClip)

        // Step C: Ingest into Database
        let savedClip = try databaseManager.ingestCapturedClip(capturedClip)
        XCTAssertEqual(savedClip.plainText, sourceText)
        XCTAssertEqual(savedClip.pasteCount, 0)

        // Step D: FTS5 search
        let searchResults = try databaseManager.searchClips(query: "blazing")
        XCTAssertEqual(searchResults.count, 1)
        XCTAssertEqual(searchResults.first?.id, savedClip.id)

        // Step E: Apply text transformation (uppercase) and paste
        try await injector.paste(
            clip: savedClip,
            databaseManager: databaseManager,
            pasteboard: pasteboard,
            transformation: .uppercase
        )

        // Step F: Verify pasteboard content transformed
        let injectedText = pasteboard.string(forType: .string)
        XCTAssertEqual(injectedText, "CONCOPY IS BLAZING FAST AND LIGHTWEIGHT")

        // Step G: Verify CGEvent synthesis
        XCTAssertEqual(mockPoster.postCommandVCalledCount, 1)

        // Step H: Verify pasteCount increment
        let updatedClip = try XCTUnwrap(databaseManager.fetchClip(id: savedClip.id))
        XCTAssertEqual(updatedClip.pasteCount, 1)
    }

    // MARK: - 2. Privacy & Blacklist Lifecycle Test
    @MainActor
    func testPrivacyAndBlacklistFilteringLifecycle() throws {
        let suiteName = "PrivacyE2E_\(UUID().uuidString)"
        let settings = AppSettingsManager(userDefaults: UserDefaults(suiteName: suiteName)!)
        settings.addExcludedApp(bundleId: "com.agilebits.onepassword")
        settings.addExcludedApp(bundleId: "com.sensitive.vault")

        var simulatedApp = "com.apple.Notes"
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            settingsManager: settings,
            frontmostAppBundleIdProvider: { simulatedApp }
        )

        // 1. Transient data -> must be ignored
        pasteboard.clearContents()
        let item1 = NSPasteboardItem()
        item1.setString("SecretToken123", forType: .string)
        item1.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.writeObjects([item1])
        XCTAssertNil(monitor.checkForChanges())

        // 2. Concealed data -> must be ignored
        pasteboard.clearContents()
        let item2 = NSPasteboardItem()
        item2.setString("MasterPassword", forType: .string)
        item2.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item2])
        XCTAssertNil(monitor.checkForChanges())

        // 3. Blacklisted application source -> must be ignored
        simulatedApp = "com.sensitive.vault"
        pasteboard.clearContents()
        pasteboard.setString("Confidential from vault", forType: .string)
        XCTAssertNil(monitor.checkForChanges())

        // 4. Allowed application -> must be captured
        simulatedApp = "com.apple.Notes"
        pasteboard.clearContents()
        pasteboard.setString("Shopping list note", forType: .string)
        let captured = monitor.checkForChanges()
        XCTAssertNotNil(captured)
        XCTAssertEqual(captured?.content, "Shopping list note")
    }

    // MARK: - 3. Screenshot Watcher Ingestion Test
    func testScreenshotWatcherAutoIngestion() throws {
        let screenshotDir = tempDir.appendingPathComponent("Screenshots", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshotDir, withIntermediateDirectories: true)

        let watcher = ScreenshotWatcher(monitoredDirectoryURL: screenshotDir)

        // Create a 100x100 dummy test image
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 100, height: 100))
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to generate test image data")
            return
        }

        let fileURL = screenshotDir.appendingPathComponent("Screenshot 2026-11-10 at 12.00.00.png")
        try pngData.write(to: fileURL)

        XCTAssertTrue(watcher.isScreenshotFile(fileURL: fileURL))

        let clip = try XCTUnwrap(watcher.processFile(at: fileURL))
        XCTAssertEqual(clip.primaryType, .image)
        XCTAssertEqual(clip.sourceAppBundleId, "com.apple.screencapture")
        XCTAssertNotNil(clip.representations["public.png"])

        let saved = try databaseManager.ingestCapturedClip(clip)
        XCTAssertEqual(saved.primaryType, .image)

        let payloads = try databaseManager.fetchPayloads(forClipId: saved.id)
        XCTAssertTrue(payloads.contains(where: { $0.utiType == "public.png" }))
    }

    // MARK: - 4. Retention & Pruning Integration Test
    func testRetentionAndPruningPolicyLifecycle() throws {
        // Ingest 4 clips
        let clip1 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Old Non-Favorite"))
        let clip2 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Old Favorite"))
        _ = try databaseManager.toggleFavorite(clipId: clip2.id)

        let clip3 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Recent Clip A"))
        let clip4 = try databaseManager.ingestCapturedClip(CapturedClip(plainText: "Recent Clip B"))

        // Backdate clip1 and clip2 to 45 days ago in SQLite
        let pastDate = Date().addingTimeInterval(-45 * 86400)
        try databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "UPDATE clips SET createdAt = ? WHERE id IN (?, ?)",
                arguments: [pastDate, clip1.id.uuidString.lowercased(), clip2.id.uuidString.lowercased()]
            )
        }

        // Run pruning with 30 days retention and maxCount 2
        let prunedCount = try databaseManager.pruneClips(olderThanDays: 30, maxCount: 2)
        XCTAssertGreaterThanOrEqual(prunedCount, 1)

        // Clip 1 (old non-favorite) must be deleted
        let checkClip1 = try databaseManager.fetchClip(id: clip1.id)
        XCTAssertNil(checkClip1)

        // Clip 2 (old FAVORITE) must be preserved
        let checkClip2 = try databaseManager.fetchClip(id: clip2.id)
        XCTAssertNotNil(checkClip2)
        XCTAssertTrue(checkClip2?.isFavorite ?? false)

        // Recent clips exist
        let checkClip3 = try databaseManager.fetchClip(id: clip3.id)
        let checkClip4 = try databaseManager.fetchClip(id: clip4.id)
        XCTAssertNotNil(checkClip3)
        XCTAssertNotNil(checkClip4)
    }
}

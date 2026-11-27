import AppKit
import GRDB
import KeyboardShortcuts
import XCTest
@testable import ConCopyCore
@testable import ConCopyUI

private final class ProductionAuditPoster: CGEventPosting, @unchecked Sendable {
    var pid: pid_t = 100
    var processes: [pid_t] = []
    var values: [String] = []
    var board: NSPasteboard?
    var onPaste: (() -> Void)?
    func isProcessTrusted() -> Bool { true }
    func postCommandV() -> Bool {
        processes.append(pid)
        values.append(board?.string(forType: .string) ?? "")
        onPaste?()
        return true
    }
    func postTab() -> Bool { true }
}

private final class ProductionAuditTextSink: NSView {
    var received: [UInt16] = []
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { received.append(event.keyCode) }
}

/// Regressions for D01–D10. No real events are posted and all storage is temporary.
@MainActor
final class ProductionAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (DatabaseManager, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopyProductionAudit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try DatabaseManager(inMemoryWithBlobDirectoryURL: root.appendingPathComponent("blobs")), root)
    }

    private func viewModel(_ db: DatabaseManager, board: NSPasteboard) throws -> ClipboardViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ProductionAudit-\(UUID())"))
        let settings = AppSettingsManager(userDefaults: defaults)
        settings.isDirectPasteEnabled = false
        return ClipboardViewModel(databaseManager: db, pasteInjector: PasteInjector(eventPoster: ProductionAuditPoster()),
            appSettings: settings, pasteboard: board)
    }

    func testD01SinglePasteMustNotFollowAnApplicationSwitch() async throws {
        let (db, _) = try fixture()
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "intended for app 100"))
        let poster = ProductionAuditPoster()
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        let ready = expectation(description: "Panel-close hook completed")
        let operation = Task { @MainActor in
            do {
                try await injector.paste(clip: clip, databaseManager: db, pasteboard: .withUniqueName(),
                    beforeEventHook: { ready.fulfill() })
            } catch {
                XCTAssertEqual((error as? CocoaError)?.code, .userCancelled)
            }
        }
        await fulfillment(of: [ready], timeout: 2)
        poster.pid = 200 // Switch after focus restoration, during the 80 ms wait.
        await operation.value
        XCTAssertEqual(poster.processes, [], "A changed destination must cancel before Command+V")
    }

    func testD02ConcurrentPastesMustNotPasteTheLastValueTwice() async throws {
        let board = NSPasteboard.withUniqueName()
        let poster = ProductionAuditPoster()
        poster.board = board
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        let ready = expectation(description: "First clipboard prepared")
        let first = Task { @MainActor in
            try await injector.pasteText("first", pasteboard: board) { _ in ready.fulfill() }
        }
        await fulfillment(of: [ready], timeout: 2)
        let second = Task { @MainActor in try await injector.pasteText("second", pasteboard: board) }
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(poster.values, ["first", "second"], "Independent paste requests must preserve their values")
    }

    func testD03LiteralSearchMustKeepUnicodeCaseAndCanonicalEquivalence() throws {
        let (db, _) = try fixture()
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "café+notes"))
        XCTAssertEqual(try db.searchClips(query: "CAFÉ").map(\.id), [clip.id], "FTS control case")
        XCTAssertEqual(try db.searchClips(query: "CAFÉ+notes").map(\.id), [clip.id], "Literal case folding")
        XCTAssertEqual(try db.searchClips(query: "cafe\u{301}+notes").map(\.id), [clip.id], "Canonical equivalence")
    }

    func testD04RestoreMustPreserveRenamedListsAndSingleAutoStar() async throws {
        let (db, root) = try fixture()
        let first = try db.createList(name: "Old list name")
        try db.setAutoStarList(listId: first.id)
        let archive = root.appendingPathComponent("archive.json")
        try await ArchiveManager().exportArchive(to: archive, databaseManager: db)
        try db.renameList(listId: first.id, newName: "New list name")
        let second = try db.createList(name: "Created after backup")
        try db.setAutoStarList(listId: second.id)
        try await ArchiveManager().importArchive(from: archive, databaseManager: db)
        let lists = try db.fetchLists()
        XCTAssertEqual(lists.first(where: { $0.id == first.id })?.name, "New list name")
        XCTAssertEqual(lists.filter(\.isAutoStarActive).count, 1, "Restore must not enable two Auto-Star lists")
    }

    func testD05FallbackMustNotDeleteBlobsOwnedByPersistentDatabase() throws {
        let (_, root) = try fixture()
        let blobs = root.appendingPathComponent("shared-blobs")
        let persistent = try DatabaseManager(diskDatabaseURL: root.appendingPathComponent("persistent.sqlite"),
            blobDirectoryURL: blobs)
        let capture = CapturedClip(plainText: "image", primaryType: .image,
            representations: ["public.png": Data(repeating: 42, count: 8192)])
        let original = try persistent.ingestCapturedClip(capture)
        let payload = try XCTUnwrap(persistent.fetchPayloads(for: original.id).first(where: { $0.blobFilename != nil }))
        // A directory cannot be opened as SQLite: exercise the same factory used at app startup.
        let startup = try DatabaseStartup.open(diskDatabaseURL: root, blobDirectoryURL: blobs)
        XCTAssertTrue(startup.isTemporary)
        XCTAssertNotNil(startup.failureDescription)
        let fallback = startup.database
        XCTAssertNotEqual(fallback.blobStorage.baseDirectoryURL, blobs)
        addTeardownBlock { try? FileManager.default.removeItem(at: fallback.blobStorage.baseDirectoryURL.deletingLastPathComponent()) }
        let temporary = try fallback.ingestCapturedClip(capture)
        try fallback.deleteClip(clipId: temporary.id)
        XCTAssertNoThrow(try persistent.loadPayloadData(for: payload), "Fallback cleanup must not corrupt persistent data")
    }

    func testD06DeleteListMustRollBackWhenAClipCannotBeDeleted() throws {
        let (db, _) = try fixture()
        let list = try db.createList(name: "Must survive failed deletion")
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "retained on error"))
        try db.assignClip(clipId: clip.id, toListId: list.id)
        try db.dbWriter.write { sql in
            try sql.execute(sql: "CREATE TRIGGER audit_reject_delete BEFORE DELETE ON clips BEGIN SELECT RAISE(ABORT,'simulated deletion failure'); END")
        }
        XCTAssertThrowsError(try db.deleteList(listId: list.id, deleteContainedClips: true))
        XCTAssertTrue(try db.fetchLists().contains(where: { $0.id == list.id }), "Failed operation must retain the list")
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.listId, list.id)
    }

    func testD07RetentionMustRecheckProtectionBeforeDeletingEachClip() throws {
        let (db, _) = try fixture()
        let keep = try db.ingestCapturedClip(CapturedClip(plainText: "newest"))
        let first = try db.ingestCapturedClip(CapturedClip(plainText: "first deletion"))
        let protect = try db.ingestCapturedClip(CapturedClip(plainText: "protected between deletions"))
        try db.dbWriter.write { sql in
            for (clip, time) in [(keep, 300.0), (first, 200.0), (protect, 100.0)] {
                try sql.execute(sql: "UPDATE clips SET updatedAt=? WHERE id=?", arguments: [Date(timeIntervalSince1970: time), clip.id.uuidString.lowercased()])
            }
            // Deterministically schedule a committed favorite change after candidate selection.
            try sql.execute(sql: """
                CREATE TRIGGER audit_protect_between_deletions AFTER DELETE ON clips
                WHEN old.id='\(first.id.uuidString.lowercased())' BEGIN
                    UPDATE clips SET isFavorite=1 WHERE id='\(protect.id.uuidString.lowercased())';
                END
                """)
        }
        _ = try db.pruneClips(maxCount: 1)
        XCTAssertEqual(try db.fetchClip(id: protect.id)?.isFavorite, true,
            "A clip protected after candidate selection must survive retention")
    }

    func testD08HealthyCloudCopyMustBeAbleToRepairOneCorruptLocalBlob() async throws {
        let (db, root) = try fixture()
        let bytes = Data(repeating: 42, count: 8192)
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "image", primaryType: .image,
            representations: ["public.png": bytes]))
        let worker = CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: root.appendingPathComponent("cloud"))
        let initial = await worker.performSync()
        XCTAssertEqual(initial.status, .idle)
        let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first(where: { $0.blobFilename != nil }))
        let filename = try XCTUnwrap(payload.blobFilename)
        try Data(repeating: 0xff, count: bytes.count).write(to: db.blobStorage.baseDirectoryURL.appendingPathComponent(filename))
        _ = try db.toggleFavorite(clipId: clip.id)
        let retry = await worker.performSync()
        XCTAssertEqual(retry.status, .idle, "A healthy remote payload must remain usable for recovery")
        XCTAssertNoThrow(try db.loadPayloadData(for: payload))
    }

    func testD09ModifiedSpaceMustNotOpenQuickLookWhileTyping() async throws {
        _ = NSApplication.shared
        let (db, _) = try fixture()
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "preview target"))
        let vm = try viewModel(db, board: .withUniqueName())
        await vm.waitForPendingLoads()
        let panel = FloatingPanel(viewModel: vm)
        vm.isSearchFocused = true
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.option], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "\u{00a0}", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        panel.sendEvent(event)
        XCTAssertFalse(vm.isQuickLookVisible, "Option+Space is text input, not the Space preview command")
        vm.isQuickLookVisible = false
        panel.orderOut(nil)
    }

    func testD01AllPasteRoutesRejectChangedDestination() async throws {
        let (db, root) = try fixture()
        for mode in 0..<4 {
            let clip = try db.ingestCapturedClip(CapturedClip(plainText: "route \(mode)"))
            let poster = ProductionAuditPoster()
            let injector = PasteInjector(eventPoster: poster, fileExporter: FilePasteExporter(exportDirectoryURL: root),
                frontmostProcessIdentifier: { poster.pid })
            let board = NSPasteboard.withUniqueName()
            do {
                switch mode {
                case 0: try await injector.paste(clip: clip, databaseManager: db, pasteboard: board,
                    beforeEventHook: { poster.pid = 200 })
                case 1: try await injector.pasteAsFile(clip: clip, databaseManager: db, pasteboard: board,
                    beforeEventHook: { poster.pid = 200 })
                case 2: try await injector.pasteBatch(clips: [clip], mode: .concatenated(separator: .newline),
                    databaseManager: db, pasteboard: board, beforeEventHook: { poster.pid = 200 })
                default: try await injector.pasteText("snippet", pasteboard: board, beforeEventHook: { _ in poster.pid = 200 })
                }
                XCTFail("Changed destination must cancel route \(mode)")
            } catch { XCTAssertEqual((error as? CocoaError)?.code, .userCancelled) }
            XCTAssertTrue(poster.processes.isEmpty)
            XCTAssertEqual(try db.fetchClip(id: clip.id)?.pasteCount, 0)
        }
    }

    func testD02DifferentInjectorsShareTheSameClipboardQueue() async throws {
        let board = NSPasteboard.withUniqueName()
        let firstPoster = ProductionAuditPoster(), secondPoster = ProductionAuditPoster()
        firstPoster.board = board; secondPoster.board = board
        let firstInjector = PasteInjector(eventPoster: firstPoster, frontmostProcessIdentifier: { firstPoster.pid })
        let secondInjector = PasteInjector(eventPoster: secondPoster, frontmostProcessIdentifier: { secondPoster.pid })
        let ready = expectation(description: "First request owns pasteboard")
        let first = Task { @MainActor in try await firstInjector.pasteText("first", pasteboard: board) { _ in ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 2)
        let second = Task { @MainActor in try await secondInjector.pasteText("second", pasteboard: board) }
        _ = try await first.value; _ = try await second.value
        XCTAssertEqual(firstPoster.values, ["first"])
        XCTAssertEqual(secondPoster.values, ["second"])
    }

    func testD02CancelledWaiterDoesNotBlockTheNextRequest() async throws {
        let board = NSPasteboard.withUniqueName(), poster = ProductionAuditPoster()
        poster.board = board
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        let ready = expectation(description: "First active"), queued = expectation(description: "Second queued")
        let first = Task { @MainActor in try await injector.pasteText("first", pasteboard: board) { _ in ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 2)
        let cancelled = Task { @MainActor in
            queued.fulfill()
            return try await injector.pasteText("cancelled", pasteboard: board)
        }
        await fulfillment(of: [queued], timeout: 2)
        cancelled.cancel()
        let last = Task { @MainActor in try await injector.pasteText("last", pasteboard: board) }
        do { _ = try await cancelled.value; XCTFail("Queued cancellation must be propagated") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await first.value; _ = try await last.value
        XCTAssertEqual(poster.values, ["first", "last"])
    }

    func testD02CancelledActiveRequestReleasesItsSlotWithoutPosting() async throws {
        let board = NSPasteboard.withUniqueName(), poster = ProductionAuditPoster()
        poster.board = board
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        let ready = expectation(description: "Prepared before cancellation")
        let first = Task { @MainActor in try await injector.pasteText("cancelled", pasteboard: board) { _ in ready.fulfill() } }
        await fulfillment(of: [ready], timeout: 2)
        first.cancel()
        do { _ = try await first.value; XCTFail("Active cancellation must be propagated") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await injector.pasteText("next", pasteboard: board)
        XCTAssertEqual(poster.values, ["next"])
    }

    func testD02CancellationAfterAnEventKeepsTheClipboardGracePeriod() async throws {
        let (db, _) = try fixture()
        let clips = try ["first", "unused"].map { try db.ingestCapturedClip(CapturedClip(plainText: $0)) }
        let board = NSPasteboard.withUniqueName(), poster = ProductionAuditPoster()
        poster.board = board
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        let posted = expectation(description: "First event posted")
        let clock = ContinuousClock()
        var eventTime: ContinuousClock.Instant?
        poster.onPaste = { if eventTime == nil { eventTime = clock.now; posted.fulfill() } }
        let first = Task { @MainActor in try await injector.pasteBatch(clips: clips,
            mode: .sequentialFormFields(delayMs: 0), databaseManager: db, pasteboard: board) }
        await fulfillment(of: [posted], timeout: 2)
        first.cancel()
        var nextWriteTime: ContinuousClock.Instant?
        let next = Task { @MainActor in try await injector.pasteText("next", pasteboard: board) { _ in nextWriteTime = clock.now } }
        do { _ = try await first.value; XCTFail("Cancel remaining batch items") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await next.value
        let start = try XCTUnwrap(eventTime), end = try XCTUnwrap(nextWriteTime)
        XCTAssertGreaterThanOrEqual(start.duration(to: end), .milliseconds(45))
        XCTAssertEqual(poster.values, ["first", "next"])
    }

    func testD02ExternalClipboardChangeCancelsWithoutOverwritingIt() async throws {
        let (db, _) = try fixture()
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "old request"))
        let board = NSPasteboard.withUniqueName(), poster = ProductionAuditPoster()
        let injector = PasteInjector(eventPoster: poster, frontmostProcessIdentifier: { poster.pid })
        do {
            try await injector.paste(clip: clip, databaseManager: db, pasteboard: board) {
                board.clearContents()
                board.setString("new user copy", forType: .string)
            }
            XCTFail("A replacement clipboard must cancel the old event")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .userCancelled) }
        XCTAssertTrue(poster.values.isEmpty)
        XCTAssertEqual(board.string(forType: .string), "new user copy")
        XCTAssertEqual(try db.fetchClip(id: clip.id)?.pasteCount, 0)
    }

    func testD05HealthyStartupRemainsPersistent() throws {
        let (_, root) = try fixture()
        let url = root.appendingPathComponent("history.sqlite"), blobs = root.appendingPathComponent("persistent-blobs")
        let startup = try DatabaseStartup.open(diskDatabaseURL: url, blobDirectoryURL: blobs)
        XCTAssertFalse(startup.isTemporary)
        XCTAssertNil(startup.failureDescription)
        _ = try startup.database.ingestCapturedClip(CapturedClip(plainText: "durable"))
        let reopened = try DatabaseStartup.open(diskDatabaseURL: url, blobDirectoryURL: blobs)
        XCTAssertFalse(reopened.isTemporary)
        XCTAssertEqual(try reopened.database.searchClips().first?.plainText, "durable")
    }

    func testD07ClearHistoryRechecksFavoritesAndListMembership() throws {
        for useList in [false, true] {
            let (db, _) = try fixture()
            let first = try db.ingestCapturedClip(CapturedClip(plainText: "first"))
            let saved = try db.ingestCapturedClip(CapturedClip(plainText: "saved during deletion"))
            let list = try db.createList(name: "Saved")
            let change = useList ? "listId='\(list.id.uuidString.lowercased())'" : "isFavorite=1"
            try db.dbWriter.write { sql in
                try sql.execute(sql: """
                    CREATE TRIGGER protect_saved AFTER DELETE ON clips WHEN old.id='\(first.id.uuidString.lowercased())'
                    BEGIN UPDATE clips SET \(change) WHERE id='\(saved.id.uuidString.lowercased())'; END
                    """)
            }
            XCTAssertEqual(try db.clearAllHistory(preserveFavorites: true), 1)
            let retained = try XCTUnwrap(db.fetchClip(id: saved.id))
            XCTAssertTrue(retained.isFavorite || retained.listId == list.id)
        }
    }

    func testD06D07RetentionRollbackKeepsRecordsAndBlobs() throws {
        let (db, _) = try fixture()
        let data = Data(repeating: 3, count: 8192)
        let first = try db.ingestCapturedClip(CapturedClip(plainText: "first", representations: ["public.rtf": data]))
        let second = try db.ingestCapturedClip(CapturedClip(plainText: "failure", representations: ["public.rtf": data]))
        let newest = try db.ingestCapturedClip(CapturedClip(plainText: "newest"))
        let payload = try XCTUnwrap(db.fetchPayloads(for: first.id).first(where: { $0.blobFilename != nil }))
        try db.dbWriter.write { sql in
            for (clip, time) in [(first, 200.0), (second, 100.0), (newest, 300.0)] {
                try sql.execute(sql: "UPDATE clips SET updatedAt=? WHERE id=?", arguments: [Date(timeIntervalSince1970: time), clip.id.uuidString.lowercased()])
            }
            try sql.execute(sql: """
                CREATE TRIGGER reject_second BEFORE DELETE ON clips WHEN old.id='\(second.id.uuidString.lowercased())'
                BEGIN SELECT RAISE(ABORT,'retention failure'); END
                """)
        }
        XCTAssertThrowsError(try db.pruneClips(maxCount: 1))
        XCTAssertEqual(try db.searchClips().count, 3)
        XCTAssertEqual(try db.loadPayloadData(for: payload), data)
    }

    func testD08ForcedRetryRepairsMissingAndTruncatedBlobsWithoutRewritingCloud() async throws {
        for missing in [false, true] {
            let (db, root) = try fixture()
            let bytes = Data(repeating: 7, count: 8192)
            let clip = try db.ingestCapturedClip(CapturedClip(plainText: "image", primaryType: .image, representations: ["public.png": bytes]))
            let worker = CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: root.appendingPathComponent("cloud"))
            let syncURL = await worker.myDeviceFileURL
            let initial = await worker.performSync()
            XCTAssertEqual(initial.status, .idle)
            let remote = try Data(contentsOf: syncURL)
            let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first(where: { $0.blobFilename != nil }))
            let filename = try XCTUnwrap(payload.blobFilename)
            let url = db.blobStorage.baseDirectoryURL.appendingPathComponent(filename)
            if missing { try FileManager.default.removeItem(at: url) }
            else { try Data([0xff]).write(to: url) }
            let repaired = await worker.performSync(force: true)
            XCTAssertEqual(repaired.status, .idle)
            XCTAssertTrue(repaired.hasLocalChanges)
            XCTAssertEqual(try db.loadPayloadData(for: payload), bytes)
            XCTAssertEqual(try Data(contentsOf: syncURL), remote)
        }
    }

    func testD08UnrelatedOrMissingRemoteDataNeverReplacesLocalContent() async throws {
        for hasRemote in [false, true] {
            let (db, root) = try fixture()
            let clip = try db.ingestCapturedClip(CapturedClip(plainText: "image", primaryType: .image,
                representations: ["public.png": Data(repeating: 7, count: 8192)]))
            let worker = CloudDriveSyncWorker(databaseManager: db, customSyncDirectoryURL: root.appendingPathComponent("cloud"))
            let syncURL = await worker.myDeviceFileURL
            _ = await worker.performSync()
            if hasRemote {
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                var state = try decoder.decode(CloudSyncState.self, from: Data(contentsOf: syncURL))
                let wrong = Data(repeating: 8, count: 8192)
                state.payloads[clip.id.uuidString.lowercased()] = [BackupPayloadItem(
                    utiType: "public.png", base64Data: wrong.base64EncodedString(), byteSize: wrong.count, sha256: CapturedClip.hash(wrong))]
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(state).write(to: syncURL)
            } else { try FileManager.default.removeItem(at: syncURL) }
            let remoteBefore = try? Data(contentsOf: syncURL)
            let payload = try XCTUnwrap(db.fetchPayloads(for: clip.id).first(where: { $0.blobFilename != nil }))
            let filename = try XCTUnwrap(payload.blobFilename)
            let url = db.blobStorage.baseDirectoryURL.appendingPathComponent(filename)
            let corrupt = Data([0xff])
            try corrupt.write(to: url)
            let retry = await worker.performSync(force: true)
            XCTAssertEqual(retry.status, .error)
            XCTAssertEqual(try db.fetchClip(id: clip.id)?.contentHash, clip.contentHash)
            XCTAssertEqual(try Data(contentsOf: url), corrupt)
            XCTAssertEqual(try? Data(contentsOf: syncURL), remoteBefore)
        }
    }

    func testD10AdvertisedShortcutsMatchRoutingInEveryFocusAndModifierMode() throws {
        let manager = GlobalShortcutsManager.shared, original = manager.swapNumericModifiers
        defer { manager.setSwapNumericModifiers(original) }
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for swapped in [false, true] {
            manager.setSwapNumericModifiers(swapped)
            for focused in [false, true] {
                for index in 0..<36 {
                    guard let shortcut = manager.quickPasteShortcut(for: index, searchFocused: focused) else { continue }
                    let modifiers: NSEvent.ModifierFlags = shortcut.modifierSymbol == "⌘" ? [.command] : [.command, .option]
                    let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                        timestamp: 0, windowNumber: 0, context: nil, characters: shortcut.label,
                        charactersIgnoringModifiers: shortcut.label, isARepeat: false, keyCode: index < 10 ? digits[index] : 255))
                    let matched = index < 10 ? manager.matchedQuickPasteIndex(for: event)
                        : manager.matchedLetterQuickPasteIndex(for: event, searchFocused: focused)
                    XCTAssertEqual(matched, index)
                }
            }
        }
    }

    func testD10RemappingACommandRemovesItsQuickPasteBadge() throws {
        let manager = GlobalShortcutsManager.shared
        let original = manager.shortcut(for: .toggleFavorite)
        defer { manager.setShortcut(original, for: .toggleFavorite) }
        XCTAssertNotNil(manager.quickPasteShortcut(for: 11, searchFocused: false))
        // Carbon key code 11 is B.
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
            timestamp: 0, windowNumber: 0, context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        manager.setShortcut(KeyboardShortcuts.Shortcut(event: event), for: .toggleFavorite)
        XCTAssertNil(manager.quickPasteShortcut(for: 11, searchFocused: false))
        XCTAssertNil(manager.matchedLetterQuickPasteIndex(for: event, searchFocused: false))
    }

    func testD09OnlyUnmodifiedSpaceOpensPreviewAndModifiedInputIsForwarded() async throws {
        _ = NSApplication.shared
        let (db, _) = try fixture()
        let vm = try viewModel(db, board: .withUniqueName())
        await vm.waitForPendingLoads()
        let panel = FloatingPanel(viewModel: vm), sink = ProductionAuditTextSink()
        panel.contentView = sink
        XCTAssertTrue(panel.makeFirstResponder(sink))
        vm.isSearchFocused = true
        for flags: NSEvent.ModifierFlags in [[.option], [.option, .shift], [.command, .control], [.function]] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ",
                charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            panel.sendEvent(event)
            XCTAssertFalse(vm.isQuickLookVisible)
        }
        XCTAssertEqual(sink.received, [49, 49, 49, 49])
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        panel.sendEvent(plain)
        XCTAssertTrue(vm.isQuickLookVisible)
        vm.isQuickLookVisible = false
        panel.orderOut(nil)
    }

    func testD03UnicodeLiteralSearchWorksAcrossPoolReaders() async throws {
        let (_, root) = try fixture()
        let db = try DatabaseManager(diskDatabaseURL: root.appendingPathComponent("pool.sqlite"),
            blobDirectoryURL: root.appendingPathComponent("pool-blobs"))
        let clip = try db.ingestCapturedClip(CapturedClip(plainText: "CAFÉ_50%"))
        _ = try db.ingestCapturedClip(CapturedClip(plainText: "cafeX50more"))
        try await withThrowingTaskGroup(of: [UUID].self) { group in
            for _ in 0..<8 {
                group.addTask { try db.searchClips(query: "cafe\u{301}_50%").map(\.id) }
            }
            for try await result in group { XCTAssertEqual(result, [clip.id]) }
        }
    }

    func testD10BadgesOnlyAdvertiseAvailableShortcuts() async throws {
        _ = NSApplication.shared
        let (db, _) = try fixture()
        for index in 0..<12 { _ = try db.ingestCapturedClip(CapturedClip(plainText: "item \(index)")) }
        let board = NSPasteboard.withUniqueName()
        let vm = try viewModel(db, board: board)
        await vm.waitForPendingLoads()
        let target = vm.clips[11]
        let shortcuts = GlobalShortcutsManager.shared
        let previous = shortcuts.swapNumericModifiers
        defer { shortcuts.setSwapNumericModifiers(previous) }
        shortcuts.setSwapNumericModifiers(false)
        XCTAssertEqual(QuickPasteShortcutMapper.label(forIndex: 10), "a")
        XCTAssertEqual(shortcuts.quickPasteModifierSymbol, "⌘⌥")
        let panel = FloatingPanel(viewModel: vm)
        vm.onClosePanel = {}
        vm.isSearchFocused = true
        XCTAssertNil(shortcuts.quickPasteShortcut(for: 10, searchFocused: true))
        XCTAssertNil(shortcuts.quickPasteShortcut(for: 10, searchFocused: false), "A remains reserved for All Clips")
        XCTAssertNil(shortcuts.quickPasteShortcut(for: 11, searchFocused: true))
        vm.isSearchFocused = false
        let shortcut = try XCTUnwrap(shortcuts.quickPasteShortcut(for: 11, searchFocused: false))
        XCTAssertEqual(shortcut.label, "b")
        XCTAssertEqual(shortcut.modifierSymbol, "⌘")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
            characters: "b", charactersIgnoringModifiers: "b", isARepeat: false, keyCode: 11))
        panel.sendEvent(event)
        await vm.waitForPendingLoads()
        XCTAssertEqual(board.string(forType: .string), target.plainText, "The displayed badge must copy its record")
        panel.orderOut(nil)
    }
}

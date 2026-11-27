#if canImport(Testing)
import Foundation
import GRDB
import Testing
@testable import ConCopyCore
@testable import ConCopyUI

struct PrivacyAuditRegressionTests {
    private let secret = "api_key=sk-1234567890abcdef1234567890abcdef"

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConCopyPrivacy-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func publishedClips(_ db: DatabaseManager, root: URL) async throws -> [ClipRecord] {
        let worker = CloudDriveSyncWorker(databaseManager: db,
            customSyncDirectoryURL: root.appendingPathComponent("sync"), deviceId: "privacy-test",
            excludeSensitiveFromSync: { true })
        let result = await worker.performSync()
        #expect(result.status == .idle)
        let url = await worker.myDeviceFileURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CloudSyncState.self, from: Data(contentsOf: url)).clips
    }

    @Test(arguments: ["v8_restore_origins_and_blob_cleanup", "v9_sensitive_sync_and_expiration"])
    func historicalSecretsAreClassifiedBeforeSync(migration: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("legacy.sqlite")
        let blobs = BlobStorageManager(baseDirectoryURL: root.appendingPathComponent("blobs"))
        let sensitive = ClipRecord(contentHash: "legacy-secret", plainText: secret, primaryType: .text)
        let ordinary = ClipRecord(contentHash: "legacy-ordinary", plainText: "ordinary text", primaryType: .text)
        let expiry = Date(timeIntervalSince1970: 4_000_000_000)
        let alreadyPrivate = ClipRecord(contentHash: "legacy-private", plainText: "manually private",
            primaryType: .text, isSensitive: true, expiresAt: expiry)
        do {
            let queue = try DatabaseQueue(path: path.path)
            try DatabaseManager.migrator(blobStorage: blobs).migrate(queue, upTo: migration)
            try ClipRecord.$omitV9ColumnsDuringLegacyInsert.withValue(migration.hasPrefix("v8")) {
                try queue.write { sql in
                    try sensitive.insert(sql)
                    try ordinary.insert(sql)
                    if migration.hasPrefix("v9") { try alreadyPrivate.insert(sql) }
                }
            }
        }
        let db = try DatabaseManager(diskDatabaseURL: path, blobDirectoryURL: blobs.baseDirectoryURL)
        #expect(try db.fetchClip(id: sensitive.id)?.isSensitive == true)
        #expect(try db.fetchClip(id: ordinary.id)?.isSensitive == false)
        if migration.hasPrefix("v9") {
            #expect(try db.fetchClip(id: alreadyPrivate.id)?.isSensitive == true)
            #expect(try db.fetchClip(id: alreadyPrivate.id)?.expiresAt == expiry)
        }
        let published = try await publishedClips(db, root: root)
        #expect(published.map(\.id) == [ordinary.id])
    }

    @Test(arguments: [1, 2], [false, true])
    func untrustedArchivePrivacyFlagsAreReclassified(version: Int, duplicate: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: root.appendingPathComponent("blobs"))
        var existingID: UUID?
        if duplicate {
            let clip = try db.ingestCapturedClip(CapturedClip(plainText: secret, primaryType: .text))
            existingID = clip.id
            try await db.dbWriter.write { sql in
                try sql.execute(sql: "UPDATE clips SET isSensitive = 0 WHERE id = ?",
                    arguments: [clip.id.uuidString.lowercased()])
            }
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let hash = CapturedClip(plainText: secret, primaryType: .text).computeContentHash()
        let item = BackupClipItem(id: UUID(), contentHash: hash, plainText: secret,
            customName: nil, primaryType: .text, sourceAppBundleId: nil, isFavorite: false,
            listId: nil, pasteCount: 0, manualSortIndex: 0, createdAt: now, updatedAt: now,
            isSensitive: false, payloads: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(ConCopyArchive(version: version, lists: [], clips: [item]))
        if version == 1 {
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var clips = try #require(json["clips"] as? [[String: Any]])
            clips[0].removeValue(forKey: "isSensitive")
            clips[0].removeValue(forKey: "expiresAt")
            json["clips"] = clips
            data = try JSONSerialization.data(withJSONObject: json)
        }
        let archive = root.appendingPathComponent("archive.json")
        try data.write(to: archive)
        try await ArchiveManager().importArchive(from: archive, databaseManager: db)
        let clips = try db.searchClips()
        let imported = try #require(clips.first)
        #expect(clips.count == 1)
        #expect(imported.isSensitive)
        if let existingID { #expect(imported.id == existingID) }
        #expect(try await publishedClips(db, root: root).isEmpty)
    }

    @Test
    func archiveDuplicatePreservesPrivacyAndEarliestExpiry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try DatabaseManager(inMemoryWithBlobDirectoryURL: root.appendingPathComponent("blobs"))
        let original = try db.ingestCapturedClip(CapturedClip(plainText: "manually private", primaryType: .text))
        let expiry = Date(timeIntervalSince1970: 4_000_000_000)
        try await db.dbWriter.write { sql in
            try sql.execute(sql: "UPDATE clips SET isSensitive = 1, expiresAt = ? WHERE id = ?",
                arguments: [expiry, original.id.uuidString.lowercased()])
        }
        for incomingExpiry in [expiry.addingTimeInterval(600), expiry.addingTimeInterval(-600)] {
            let item = BackupClipItem(id: UUID(), contentHash: original.contentHash,
                plainText: original.plainText, customName: nil, primaryType: .text,
                sourceAppBundleId: nil, isFavorite: false, listId: nil, pasteCount: 0,
                manualSortIndex: 0, createdAt: original.createdAt, updatedAt: original.updatedAt,
                isSensitive: false, expiresAt: incomingExpiry, payloads: [])
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let archive = root.appendingPathComponent("archive.json")
            try encoder.encode(ConCopyArchive(lists: [], clips: [item])).write(to: archive)
            try await ArchiveManager().importArchive(from: archive, databaseManager: db)
            let restored = try #require(try db.fetchClip(id: original.id))
            #expect(restored.isSensitive)
            #expect(restored.expiresAt == min(expiry, incomingExpiry))
        }
    }

    @Test(arguments: ["", "RSA ", "EC ", "OPENSSH ", "DSA ", "ENCRYPTED "])
    func privateKeyMaskHidesEntireBody(kind: String) {
        let key = "-----BEGIN \(kind)PRIVATE KEY-----\r\nSENSITIVEKEYBODY1234567890\r\n-----END \(kind)PRIVATE KEY-----"
        let masked = SensitiveDataDetector.maskSensitiveText("before\n\(key)\nafter")
        #expect(masked == "before\n-----BEGIN PRIVATE KEY [HIDDEN]-----\nafter")
        #expect(SensitiveDataDetector.isSensitive(key))
    }

    @Test
    func multipleAndTruncatedPrivateKeysDoNotLeakBodies() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\none-secret\n-----END RSA PRIVATE KEY-----\nseparator\n-----BEGIN PRIVATE KEY-----\ntwo-secret-without-footer"
        let masked = SensitiveDataDetector.maskSensitiveText(text)
        #expect(masked == "-----BEGIN PRIVATE KEY [HIDDEN]-----\nseparator\n-----BEGIN PRIVATE KEY [HIDDEN]-----")
    }

    @Test
    func accessibilityAndPreviewUseSamePrivacyPolicy() {
        let masked = ClipRowTextPresentation(plainText: secret, fallbackTitle: "text",
            shouldMaskSensitive: true, isRevealed: false)
        #expect(masked.preview == SensitiveDataDetector.maskSensitiveText(secret))
        #expect(masked.accessibilityTitle == masked.preview)
        #expect(!masked.accessibilityTitle.contains("1234567890abcdef"))
        for (shouldMask, revealed) in [(true, true), (false, false)] {
            let visible = ClipRowTextPresentation(plainText: secret, fallbackTitle: "text",
                shouldMaskSensitive: shouldMask, isRevealed: revealed)
            #expect(visible.preview == secret)
            #expect(visible.accessibilityTitle == secret)
        }
        let fallback = ClipRowTextPresentation(plainText: nil, fallbackTitle: "image",
            shouldMaskSensitive: true, isRevealed: false)
        #expect(fallback.accessibilityTitle == "image")
        let longSecret = String(repeating: "a ", count: 72) + "password=supersecretvalue123456789"
        let longMasked = ClipRowTextPresentation(plainText: longSecret, fallbackTitle: "text",
            shouldMaskSensitive: true, isRevealed: false)
        #expect(longMasked.accessibilityTitle == String(SensitiveDataDetector.maskSensitiveText(longSecret).prefix(160)))
        #expect(!longMasked.accessibilityTitle.contains("supers"))
    }
}
#endif

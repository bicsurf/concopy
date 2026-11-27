import Foundation
import GRDB

public enum CloudSyncStatus: String, Sendable, Codable { case idle, syncing, unavailable, error }

/// Version 2 adds payloads and an independent mutation clock (favorites must not reorder history).
public struct CloudSyncState: Codable, Sendable {
    public var version: Int
    public var lastModifiedDeviceId: String
    public var updatedAt: Date
    public var clips: [ClipRecord]
    public var tombstones: [String: Date]
    public var lists: [ClipListRecord]
    public var snippets: [SnippetRecord]
    public var payloads: [String: [BackupPayloadItem]]
    public var revisions: [String: Date]
    public var listTombstones: [String: Date]
    public var snippetTombstones: [String: Date]
    public var aliases: [String: String]
    /// Grow-only components keep usage independent of content revisions and preserve offline increments.
    public var usage: [String: [String: Int]]
    public var metadataRevisions: [String: [String: Date]]
    public var snippetOrigins: [SnippetRestoreOrigin]

    public init(
        version: Int = 2, lastModifiedDeviceId: String = "", updatedAt: Date = Date(),
        clips: [ClipRecord] = [], tombstones: [String: Date] = [:], lists: [ClipListRecord] = [],
        snippets: [SnippetRecord] = [], payloads: [String: [BackupPayloadItem]] = [:],
        revisions: [String: Date] = [:], listTombstones: [String: Date] = [:],
        snippetTombstones: [String: Date] = [:], aliases: [String: String] = [:],
        usage: [String: [String: Int]] = [:], metadataRevisions: [String: [String: Date]] = [:],
        snippetOrigins: [SnippetRestoreOrigin] = []
    ) {
        self.version = version
        self.lastModifiedDeviceId = lastModifiedDeviceId
        self.updatedAt = updatedAt
        self.clips = clips
        self.tombstones = tombstones
        self.lists = lists
        self.snippets = snippets
        self.payloads = payloads
        self.revisions = revisions
        self.listTombstones = listTombstones
        self.snippetTombstones = snippetTombstones
        self.aliases = aliases
        self.usage = usage
        self.metadataRevisions = metadataRevisions
        self.snippetOrigins = snippetOrigins
    }

    private enum CodingKeys: String, CodingKey {
        case version, lastModifiedDeviceId, updatedAt, clips, tombstones, lists, snippets, payloads
        case revisions, listTombstones, snippetTombstones, aliases, usage, metadataRevisions, snippetOrigins
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        guard (1...2).contains(version) else { throw ArchiveError.unsupportedVersion(version) }
        lastModifiedDeviceId = try c.decode(String.self, forKey: .lastModifiedDeviceId)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        clips = try c.decode([ClipRecord].self, forKey: .clips)
        func decodeDates(_ key: CodingKeys) throws -> [String: Date] {
            if let seconds = try? c.decode([String: Double].self, forKey: key) {
                return seconds.mapValues { Date(timeIntervalSince1970: $0) }
            }
            return try c.decodeIfPresent([String: Date].self, forKey: key) ?? [:]
        }
        tombstones = try decodeDates(.tombstones)
        lists = try c.decodeIfPresent([ClipListRecord].self, forKey: .lists) ?? []
        snippets = try c.decodeIfPresent([SnippetRecord].self, forKey: .snippets) ?? []
        payloads = try c.decodeIfPresent([String: [BackupPayloadItem]].self, forKey: .payloads) ?? [:]
        if let seconds = try? c.decode([String: Double].self, forKey: .revisions) {
            revisions = seconds.mapValues { Date(timeIntervalSince1970: $0) }
        } else {
            revisions = try c.decodeIfPresent([String: Date].self, forKey: .revisions) ?? [:]
        }
        listTombstones = try decodeDates(.listTombstones)
        snippetTombstones = try decodeDates(.snippetTombstones)
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        usage = try c.decodeIfPresent([String: [String: Int]].self, forKey: .usage) ?? [:]
        snippetOrigins = try c.decodeIfPresent([SnippetRestoreOrigin].self, forKey: .snippetOrigins) ?? []
        if let seconds = try? c.decode([String: [String: Double]].self, forKey: .metadataRevisions) {
            metadataRevisions = seconds.mapValues { $0.mapValues { Date(timeIntervalSince1970: $0) } }
        } else {
            metadataRevisions = try c.decodeIfPresent([String: [String: Date]].self, forKey: .metadataRevisions) ?? [:]
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(lastModifiedDeviceId, forKey: .lastModifiedDeviceId)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(clips, forKey: .clips)
        try c.encode(tombstones.mapValues(\.timeIntervalSince1970), forKey: .tombstones)
        try c.encode(lists, forKey: .lists)
        try c.encode(snippets, forKey: .snippets)
        try c.encode(payloads, forKey: .payloads)
        // Preserve subsecond mutation ordering even with legacy ISO-8601 date strategies.
        try c.encode(revisions.mapValues(\.timeIntervalSince1970), forKey: .revisions)
        try c.encode(listTombstones.mapValues(\.timeIntervalSince1970), forKey: .listTombstones)
        try c.encode(snippetTombstones.mapValues(\.timeIntervalSince1970), forKey: .snippetTombstones)
        try c.encode(aliases, forKey: .aliases)
        try c.encode(usage, forKey: .usage)
        try c.encode(metadataRevisions.mapValues { $0.mapValues(\.timeIntervalSince1970) }, forKey: .metadataRevisions)
        try c.encode(snippetOrigins, forKey: .snippetOrigins)
    }
    static func id(_ id: UUID) -> String { id.uuidString.lowercased() }
    static func key(_ kind: String, _ id: UUID) -> String { kind + ":" + self.id(id) }
}

private struct SyncClipValue: Encodable {
    var record: ClipRecord
    var payloads: [BackupPayloadItem]
}

public actor CloudDriveSyncWorker {
    public let syncDirectoryURL: URL
    public let syncFileURL: URL
    public let legacySyncFileURL: URL
    public let devicesDirectoryURL: URL
    public let myDeviceFileURL: URL
    public let deviceId: String
    private let databaseManager: DatabaseManager
    private let excludeSensitiveFromSyncProvider: @Sendable () -> Bool
    private let startDownload: @Sendable (URL) throws -> Void
    private var lastFingerprint: String?

    private func fingerprint(remoteDigest: String, excludeSensitive: Bool, in database: Database? = nil) throws -> String {
        func journal(_ db: Database) throws -> String {
            try String.fetchOne(db, sql:
                "SELECT group_concat(kind || id || printf('%.17g',modifiedAt) || deleted) FROM (SELECT * FROM sync_changes ORDER BY kind,id)") ?? ""
        }
        let changes = try database.map(journal) ?? databaseManager.dbWriter.read(journal)
        let ownFileExists = FileManager.default.fileExists(atPath: myDeviceFileURL.path)
        return "\(remoteDigest):\(excludeSensitive):\(ownFileExists):" + CapturedClip.hash(Data(changes.utf8))
    }

    /// Include placeholder names so a peer that has not downloaded yet cannot be silently skipped.
    private func remoteFileURLs() throws -> [URL] {
        var urls = Set([syncFileURL, legacySyncFileURL])
        for directory in [syncDirectoryURL, devicesDirectoryURL] {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
                let name = entry.hasPrefix(".") && entry.hasSuffix(".icloud")
                    ? String(entry.dropFirst().dropLast(".icloud".count)) : entry
                guard name.hasSuffix(".json"), !name.hasPrefix(".") else { continue }
                if directory == syncDirectoryURL && !name.hasPrefix("sync-state-v2") { continue }
                let url = directory.appendingPathComponent(name)
                if url != myDeviceFileURL { urls.insert(url) }
            }
        }
        return urls.sorted { $0.path < $1.path }
    }

    private static func removingClips(_ ids: Set<String>, from state: CloudSyncState) -> CloudSyncState {
        var result = state
        result.clips.removeAll { ids.contains(CloudSyncState.id($0.id)) }
        result.payloads = result.payloads.filter { !ids.contains($0.key) }
        result.usage = result.usage.filter { !ids.contains($0.key) }
        result.metadataRevisions = result.metadataRevisions.filter { !ids.contains($0.key) }
        result.revisions = result.revisions.filter { !ids.contains(String($0.key.dropFirst("clip:".count))) || !$0.key.hasPrefix("clip:") }
        result.tombstones = result.tombstones.filter { !ids.contains($0.key) }
        result.aliases = result.aliases.filter { !ids.contains($0.key) && !ids.contains($0.value) }
        return result
    }

    public init(
        databaseManager: DatabaseManager,
        customSyncDirectoryURL: URL? = nil,
        deviceId: String? = nil,
        excludeSensitiveFromSync: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.object(forKey: ConCopySettingsKeys.excludeSensitiveFromSyncKey) != nil
                ? UserDefaults.standard.bool(forKey: ConCopySettingsKeys.excludeSensitiveFromSyncKey)
                : true
        },
        startDownload: @escaping @Sendable (URL) throws -> Void = {
            try FileManager.default.startDownloadingUbiquitousItem(at: $0)
        }
    ) {
        self.databaseManager = databaseManager
        syncDirectoryURL =
            customSyncDirectoryURL
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ConCopy", isDirectory: true)
        syncFileURL = syncDirectoryURL.appendingPathComponent("sync-state-v2.json")
        legacySyncFileURL = syncDirectoryURL.appendingPathComponent("sync-state-v1.json")
        let assignedDeviceId = deviceId ?? DeviceIdentifierProvider.currentDeviceId()
        self.deviceId = assignedDeviceId
        devicesDirectoryURL = syncDirectoryURL.appendingPathComponent("devices", isDirectory: true)
        myDeviceFileURL = devicesDirectoryURL.appendingPathComponent("\(assignedDeviceId).json")
        self.excludeSensitiveFromSyncProvider = excludeSensitiveFromSync
        self.startDownload = startDownload
    }

    public func addTombstone(clipId: UUID) throws {
        try databaseManager.dbWriter.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted) VALUES ('clip',?,?,1)",
                arguments: [CloudSyncState.id(clipId), Date().timeIntervalSince1970])
        }
    }
    public func isDriveAvailable() -> Bool {
        FileManager.default.fileExists(atPath: syncDirectoryURL.deletingLastPathComponent().path)
    }

    private func isDownloadPending(_ url: URL) throws -> Bool {
        let placeholder = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
        let hasPlaceholder = !FileManager.default.fileExists(atPath: url.path)
            && FileManager.default.fileExists(atPath: placeholder.path)
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if hasPlaceholder || (values?.isUbiquitousItem == true && values?.ubiquitousItemDownloadingStatus != .current) {
            try startDownload(url)
            return true
        }
        return false
    }

    public func performSync(force: Bool = false, isAuthorized: @Sendable () -> Bool = { true }) async -> (
        hasLocalChanges: Bool, status: CloudSyncStatus
    ) {
        guard isAuthorized(), !Task.isCancelled else { return (false, .idle) }
        guard isDriveAvailable() else { return (false, .unavailable) }
        var rollbackBlobs: [String] = []
        do {
            try FileManager.default.createDirectory(at: syncDirectoryURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: devicesDirectoryURL, withIntermediateDirectories: true)
            let remoteURLs = try remoteFileURLs()
            for url in remoteURLs + [myDeviceFileURL] where try isDownloadPending(url) { return (false, .syncing) }
            // Hash the actual input bytes, including peers, rather than only our own file's attributes.
            let inputs = try remoteURLs.compactMap { url -> (URL, Data)? in
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (url, try Data(contentsOf: url))
            }
            let remoteDigest = CapturedClip.hash(inputs.reduce(into: Data()) { bytes, input in
                bytes.append(Data(input.0.path.utf8)); bytes.append(0)
                bytes.append(Data(CapturedClip.hash(input.1).utf8)); bytes.append(0)
            })
            let excludeSensitive = excludeSensitiveFromSyncProvider()
            let currentFingerprint = try fingerprint(remoteDigest: remoteDigest, excludeSensitive: excludeSensitive)
            if !force && currentFingerprint == lastFingerprint { return (false, .idle) }
            var coordinationError: NSError?
            var result: Result<Bool, Error> = .success(false)
            var obsoleteBlobs: [String] = []
            var publishedFingerprint: String?
            // Each device owns exactly one writable file. Legacy shared files are import-only.
            NSFileCoordinator().coordinate(writingItemAt: myDeviceFileURL, options: .forMerging, error: &coordinationError)
            { url in
                result = Result {
                    try Task.checkCancellation()
                    guard isAuthorized() else { throw CancellationError() }
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    var remote = CloudSyncState(updatedAt: .distantPast)
                    for (inputURL, data) in inputs {
                        do {
                            remote = try Self.merge(remote, decoder.decode(CloudSyncState.self, from: data))
                            for conflict in NSFileVersion.unresolvedConflictVersionsOfItem(at: inputURL) ?? [] {
                                remote = try Self.merge(remote, decoder.decode(CloudSyncState.self, from: Data(contentsOf: conflict.url)))
                            }
                        } catch {
                            if inputURL == self.syncFileURL || inputURL == self.legacySyncFileURL { throw error }
                            ConCopyLogger.sync.error("Skipping invalid peer sync file: \(error.localizedDescription, privacy: .private)")
                        }
                    }

                    // Recover validated bytes from our own snapshot without replaying its metadata.
                    var recovery = remote
                    if FileManager.default.fileExists(atPath: url.path) {
                        do {
                            let own = try decoder.decode(CloudSyncState.self, from: Data(contentsOf: url))
                            for (id, payloads) in own.payloads {
                                recovery.payloads[id, default: []].append(contentsOf: payloads)
                            }
                        } catch {
                            ConCopyLogger.sync.error("Skipping invalid local cloud recovery snapshot: \(error.localizedDescription, privacy: .private)")
                        }
                    }

                    var changed = false
                    // Keep the writer locked across snapshot + merge + apply; local edits cannot be overwritten by a stale snapshot.
                    try databaseManager.dbWriter.write { db in
                        let (local, repaired) = try self.snapshot(db, repairingFrom: recovery, isAuthorized: isAuthorized)
                        // Local private clips must survive remote withdrawals and stale peer copies.
                        let privateClips = excludeSensitive ? local.clips.filter(\.isSensitive) : []
                        let privateHashes = Set(privateClips.map(\.contentHash))
                        let privateIds = Set(privateClips.map { CloudSyncState.id($0.id) })
                            .union(remote.clips.filter { privateHashes.contains($0.contentHash) }
                                .map { CloudSyncState.id($0.id) })
                        let protectedRemote = Self.removingClips(privateIds, from: remote)
                        let merged = try Self.merge(local, protectedRemote)
                        try Task.checkCancellation()
                        guard isAuthorized() else { throw CancellationError() }
                        let applied = try self.apply(merged, in: db, obsoleteBlobs: &obsoleteBlobs, rollbackBlobs: &rollbackBlobs)
                        changed = repaired || applied

                        let privatePublicationIds = excludeSensitive
                            ? Set(merged.clips.filter(\.isSensitive).map { CloudSyncState.id($0.id) }) : []
                        var publicationState = Self.removingClips(privatePublicationIds, from: merged)
                        // Withdraw previously published content without deleting the protected local copy.
                        for id in privatePublicationIds {
                            publicationState.tombstones[id] = merged.revisions["clip:" + id]
                                ?? merged.clips.first { CloudSyncState.id($0.id) == id }?.updatedAt ?? Date()
                        }

                        let encoder = JSONEncoder()
                        encoder.dateEncodingStrategy = .iso8601
                        encoder.outputFormatting = [.sortedKeys]
                        let encoded = try encoder.encode(publicationState)

                        // Write to devices/<deviceId>.json atomically
                        try self.atomicWrite(data: encoded, to: self.myDeviceFileURL)

                        // Checkpoint only the inputs consumed and the transaction just published.
                        publishedFingerprint = try self.fingerprint(remoteDigest: remoteDigest, excludeSensitive: excludeSensitive, in: db)
                    }
                    return changed
                }
            }
            if let coordinationError { throw coordinationError }
            let changed = try result.get()
            try databaseManager.removeUnreferencedBlobs(obsoleteBlobs)
            lastFingerprint = publishedFingerprint
            return (changed, .idle)
        } catch is CancellationError {
            try? databaseManager.removeUnreferencedBlobs(rollbackBlobs)
            return (false, .idle)
        } catch {
            try? databaseManager.removeUnreferencedBlobs(rollbackBlobs)
            return (false, .error)
        }
    }

    private func atomicWrite(data: Data, to destinationURL: URL) throws {
        let parentDir = destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        if (try? Data(contentsOf: destinationURL)) == data { return }
        let tempURL = parentDir.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp.\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try data.write(to: tempURL)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        }
    }

    /// Repair only exact content-addressed bytes. Never replace a local edit with a remote record
    /// merely because its ID matches, and never publish an incomplete snapshot as a recovery shortcut.
    private func repairLocalBlobs(from remote: CloudSyncState, in db: Database,
        isAuthorized: @Sendable () -> Bool) throws -> Bool
    {
        var damaged: [ClipPayloadRecord] = []
        let payloads = try ClipPayloadRecord.filter(Column("blobFilename") != nil).fetchAll(db)
        for payload in payloads {
            if let bytes = try? databaseManager.loadPayloadData(for: payload), bytes.count == payload.byteSize { continue }
            damaged.append(payload)
        }
        guard !damaged.isEmpty else { return false }
        let needed = Set(damaged.compactMap(\.blobFilename))
        var verified: [String: Data] = [:]
        for saved in remote.payloads.values {
            for item in saved where item.byteSize > 4096 {
                if let hash = item.sha256, !needed.contains(hash + ".blob") { continue }
                try autoreleasepool {
                    for bytes in try ArchiveManager.validatedRepresentations([item]).values {
                        let filename = CapturedClip.hash(bytes) + ".blob"
                        if needed.contains(filename) { verified[filename] = bytes }
                    }
                }
            }
        }
        // Verify the whole recovery set before changing any files.
        for payload in damaged {
            guard let filename = payload.blobFilename, let bytes = verified[filename], bytes.count == payload.byteSize else {
                throw BlobStorageError.corruptedBlob
            }
        }
        for bytes in verified.values {
            try Task.checkCancellation()
            guard isAuthorized() else { throw CancellationError() }
            _ = try databaseManager.blobStorage.storeBlob(data: bytes)
        }
        return true
    }

    private func snapshot(_ db: Database, repairingFrom remote: CloudSyncState,
        isAuthorized: @Sendable () -> Bool) throws -> (CloudSyncState, Bool)
    {
        do { return (try snapshot(db), false) }
        catch {
            guard try repairLocalBlobs(from: remote, in: db, isAuthorized: isAuthorized) else { throw error }
            return (try snapshot(db), true)
        }
    }

    private func snapshot(_ db: Database) throws -> CloudSyncState {
        let archive = try databaseManager.makeArchive(in: db)
        let eligibleClips = archive.clips

        var state = CloudSyncState(
            lastModifiedDeviceId: deviceId, updatedAt: .distantPast,
            clips: eligibleClips.map { $0.record() }, lists: archive.lists, snippets: archive.snippets, usage: archive.usage,
            snippetOrigins: archive.snippetOrigins)
        for item in eligibleClips { state.payloads[CloudSyncState.id(item.id)] = item.payloads }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM sync_changes") {
            let kind: String = row["kind"]
            if kind == "usage" || kind == "metadata" { continue }
            let id: String = row["id"]
            let timestamp: Double = row["modifiedAt"]
            let date = Date(timeIntervalSince1970: timestamp)
            state.revisions[kind + ":" + id] = date
            let deleted: Bool = row["deleted"]
            if deleted {
                switch kind {
                case "clip": state.tombstones[id] = date
                case "list": state.listTombstones[id] = date
                case "snippet": state.snippetTombstones[id] = date
                default: break
                }
            }
        }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM sync_aliases") {
            let alias: String = row["alias"]
            let canonical: String = row["canonical"]
            state.aliases[alias] = canonical
        }
        for row in try Row.fetchAll(db, sql: "SELECT clipId,field,modifiedAt FROM sync_clip_metadata") {
            let id: String = row["clipId"], field: String = row["field"], seconds: Double = row["modifiedAt"]
            state.metadataRevisions[id, default: [:]][field] = Date(timeIntervalSince1970: seconds)
        }
        return state
    }

    /// Deterministic last-writer merge. Tombstones are retained so long-offline Macs cannot resurrect deletions.
    internal static func merge(_ local: CloudSyncState, _ remote: CloudSyncState) throws -> CloudSyncState {
        var merged = CloudSyncState(updatedAt: .distantPast)
        func dates(_ a: [String: Date], _ b: [String: Date]) -> [String: Date] { a.merging(b, uniquingKeysWith: max) }
        merged.revisions = dates(local.revisions, remote.revisions)
        merged.tombstones = dates(local.tombstones, remote.tombstones)
        merged.listTombstones = dates(local.listTombstones, remote.listTombstones)
        merged.snippetTombstones = dates(local.snippetTombstones, remote.snippetTombstones)
        merged.aliases = local.aliases.merging(remote.aliases) { min($0, $1) }
        func canonical(_ id: String) throws -> String {
            var target = id
            var visited = Set<String>()
            while let next = merged.aliases[target] {
                guard visited.insert(target).inserted else { throw ArchiveError.invalidPayload("cyclic sync alias") }
                target = next
            }
            return target
        }
        // Identity precedes content deduplication: an offline edit must first reach its canonical record.
        for alias in merged.aliases.keys.sorted() { merged.aliases[alias] = try canonical(alias) }
        func revision(_ state: CloudSyncState, _ kind: String, _ id: UUID, _ fallback: Date) -> Date {
            state.revisions[CloudSyncState.key(kind, id)] ?? fallback
        }
        func wins<T: Encodable>(_ incoming: T, _ current: T, _ incomingDate: Date, _ currentDate: Date) throws -> Bool {
            if incomingDate != currentDate { return incomingDate > currentDate }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(incoming).lexicographicallyPrecedes(encoder.encode(current))
        }
        var clips: [UUID: ClipRecord] = [:]
        var lists: [UUID: ClipListRecord] = [:]
        var snippets: [UUID: SnippetRecord] = [:]
        var clipVersions: [UUID: Date] = [:]
        var listVersions: [UUID: Date] = [:]
        var snippetVersions: [UUID: Date] = [:]
        var metadata: [UUID: [ClipMetadataField: VersionedClipMetadata]] = [:]
        var firstCapture: [UUID: Date] = [:]
        var lastActivity: [UUID: Date] = [:]
        func combineMetadata(_ values: [ClipMetadataField: VersionedClipMetadata], into id: UUID) {
            for (field, incoming) in values {
                if let current = metadata[id]?[field], !incoming.wins(over: current) { continue }
                metadata[id, default: [:]][field] = incoming
            }
        }
        func count(_ components: [String: Int]) throws -> Int {
            try components.values.reduce(0) { total, value in
                let sum = total.addingReportingOverflow(value)
                guard value >= 0, !sum.overflow else { throw ArchiveError.invalidPayload("usage counter") }
                return sum.partialValue
            }
        }
        func clipValue(_ clip: ClipRecord, _ payloads: [BackupPayloadItem]) -> SyncClipValue {
            var record = clip
            record.pasteCount = 0 // Usage is merged independently of the content winner.
            record.isFavorite = false
            record.customName = nil
            record.listId = nil
            record.manualSortIndex = 0
            record.createdAt = .distantPast
            record.updatedAt = .distantPast
            return SyncClipValue(record: record, payloads: payloads.sorted { $0.utiType < $1.utiType })
        }
        for state in [local, remote] {
            for var clip in state.clips {
                let originalID = clip.id
                let originalKey = CloudSyncState.id(originalID)
                let key = try canonical(originalKey)
                guard let id = UUID(uuidString: key) else { throw ArchiveError.invalidPayload("clip identity") }
                let date = revision(state, "clip", originalID, clip.updatedAt)
                clip.id = id
                firstCapture[id] = min(firstCapture[id] ?? clip.createdAt, clip.createdAt)
                lastActivity[id] = max(lastActivity[id] ?? clip.updatedAt, clip.updatedAt)
                var fields: [ClipMetadataField: VersionedClipMetadata] = [:]
                for field in ClipMetadataField.allCases {
                    let value = field.value(in: clip)
                    let stamp = state.metadataRevisions[originalKey]?[field.rawValue]
                        ?? (value.isDefault ? .distantPast : date)
                    fields[field] = VersionedClipMetadata(value: value, modifiedAt: stamp)
                }
                combineMetadata(fields, into: id)
                var components = state.usage[originalKey] ?? [:]
                let known = try count(components)
                if clip.pasteCount > known {
                    components["legacy:" + originalKey, default: 0] += clip.pasteCount - known
                }
                merged.usage[key] = (merged.usage[key] ?? [:]).merging(components, uniquingKeysWith: max)
                var payloads = state.payloads[originalKey] ?? []
                if payloads.isEmpty, let text = clip.plainText {
                    payloads = [
                        BackupPayloadItem(
                            utiType: "public.utf8-plain-text", base64Data: Data(text.utf8).base64EncodedString(),
                            byteSize: text.utf8.count)
                    ]
                }
                let representations = try ArchiveManager.validatedRepresentations(payloads)
                clip.contentHash = CapturedClip(plainText: clip.plainText, primaryType: clip.primaryType,
                    representations: representations).migratedContentHash(fallback: clip.contentHash)
                if let existing = clips[id],
                    !(try wins(clipValue(clip, payloads), clipValue(existing, merged.payloads[key] ?? []),
                        date, clipVersions[id] ?? .distantPast)) { continue }
                clips[id] = clip
                clipVersions[id] = date
                merged.revisions[CloudSyncState.key("clip", id)] = date
                merged.payloads[key] = payloads
            }
            for list in state.lists {
                let date = revision(state, "list", list.id, list.createdAt)
                if let existing = lists[list.id],
                    !(try wins(list, existing, date, listVersions[list.id] ?? .distantPast))
                {
                    continue
                }
                lists[list.id] = list
                listVersions[list.id] = date
                merged.revisions[CloudSyncState.key("list", list.id)] = date
            }
            for snippet in state.snippets {
                let date = revision(state, "snippet", snippet.id, snippet.updatedAt)
                if let existing = snippets[snippet.id],
                    !(try wins(snippet, existing, date, snippetVersions[snippet.id] ?? .distantPast))
                {
                    continue
                }
                snippets[snippet.id] = snippet
                snippetVersions[snippet.id] = date
                merged.revisions[CloudSyncState.key("snippet", snippet.id)] = date
            }
        }
        // Independently captured equal content converges to one stable ID; remember aliases for offline deletions.
        let groups = Dictionary(grouping: clips.values, by: \.contentHash)
        for group in groups.values where group.count > 1 {
            let sorted = group.sorted { CloudSyncState.id($0.id) < CloudSyncState.id($1.id) }
            guard let canonical = sorted.first else { continue }
            let canonicalID = CloudSyncState.id(canonical.id)
            var winner = canonical
            for clip in sorted.dropFirst() {
                merged.aliases[CloudSyncState.id(clip.id)] = canonicalID
                combineMetadata(metadata[clip.id] ?? [:], into: canonical.id)
                firstCapture[canonical.id] = min(firstCapture[canonical.id] ?? clip.createdAt, firstCapture[clip.id] ?? clip.createdAt)
                lastActivity[canonical.id] = max(lastActivity[canonical.id] ?? clip.updatedAt, lastActivity[clip.id] ?? clip.updatedAt)
                if try wins(
                    clip, winner, clipVersions[clip.id] ?? clip.updatedAt, clipVersions[winner.id] ?? winner.updatedAt)
                {
                    winner = clip
                }
                clips.removeValue(forKey: clip.id)
            }
            let payloads = merged.payloads[CloudSyncState.id(winner.id)] ?? []
            let date = clipVersions[winner.id] ?? winner.updatedAt
            winner.id = canonical.id
            clips[canonical.id] = winner
            clipVersions[canonical.id] = date
            merged.revisions[CloudSyncState.key("clip", canonical.id)] = date
            merged.payloads[canonicalID] = payloads
        }
        for (alias, _) in merged.aliases {
            var target = alias
            var visited = Set<String>()
            while let next = merged.aliases[target], visited.insert(target).inserted { target = next }
            if visited.contains(target) { throw ArchiveError.invalidPayload("cyclic sync alias") }
            merged.aliases[alias] = target
            if let date = merged.tombstones[alias] {
                merged.tombstones[target] = max(date, merged.tombstones[target] ?? .distantPast)
            }
        }
        var normalizedUsage: [String: [String: Int]] = [:]
        for (id, components) in merged.usage {
            let key = try canonical(id)
            normalizedUsage[key] = (normalizedUsage[key] ?? [:]).merging(components, uniquingKeysWith: max)
        }
        merged.usage = normalizedUsage
        merged.clips = clips.values.filter {
            (merged.tombstones[CloudSyncState.id($0.id)] ?? .distantPast) < (clipVersions[$0.id] ?? $0.updatedAt)
        }.sorted { CloudSyncState.id($0.id) < CloudSyncState.id($1.id) }
        for i in merged.clips.indices {
            let id = merged.clips[i].id, key = CloudSyncState.id(id)
            merged.clips[i].pasteCount = try count(merged.usage[key] ?? [:])
            merged.clips[i].createdAt = firstCapture[id] ?? merged.clips[i].createdAt
            merged.clips[i].updatedAt = lastActivity[id] ?? merged.clips[i].updatedAt
            for (field, candidate) in metadata[id] ?? [:] {
                candidate.value.apply(to: &merged.clips[i])
                if candidate.modifiedAt != .distantPast {
                    merged.metadataRevisions[key, default: [:]][field.rawValue] = candidate.modifiedAt
                }
            }
        }
        merged.lists = lists.values.filter {
            (merged.listTombstones[CloudSyncState.id($0.id)] ?? .distantPast) < (listVersions[$0.id] ?? $0.createdAt)
        }.sorted { CloudSyncState.id($0.id) < CloudSyncState.id($1.id) }
        merged.snippets = snippets.values.filter {
            (merged.snippetTombstones[CloudSyncState.id($0.id)] ?? .distantPast)
                < (snippetVersions[$0.id] ?? $0.updatedAt)
        }.sorted { CloudSyncState.id($0.id) < CloudSyncState.id($1.id) }
        let snippetIDs = Set(merged.snippets.map(\.id))
        var origins: [String: SnippetRestoreOrigin] = [:]
        for origin in local.snippetOrigins + remote.snippetOrigins where snippetIDs.contains(origin.restoredId) {
            let key = origin.originalId.uuidString.lowercased() + ":" + origin.payloadHash
            if let current = origins[key], current.restoredId.uuidString < origin.restoredId.uuidString { continue }
            origins[key] = origin
        }
        merged.snippetOrigins = origins.keys.sorted().compactMap { origins[$0] }
        let listIDs = Set(merged.lists.map(\.id))
        for i in merged.clips.indices where merged.clips[i].listId.map({ !listIDs.contains($0) }) ?? false {
            merged.clips[i].listId = nil
        }
        var activeListSeen = false
        for i in merged.lists.indices where merged.lists[i].isAutoStarActive {
            merged.lists[i].isAutoStarActive = !activeListSeen
            activeListSeen = true
        }
        let reservedShortcuts = Set(merged.snippets.map(\.shortcut))
        var shortcuts = Set<String>()
        for i in merged.snippets.indices {
            if !shortcuts.insert(merged.snippets[i].shortcut).inserted {
                let base = merged.snippets[i].shortcut + "~" + CloudSyncState.id(merged.snippets[i].id)
                var candidate = base
                var suffix = 1
                while reservedShortcuts.contains(candidate) || shortcuts.contains(candidate) {
                    candidate = base + "~\(suffix)"
                    suffix += 1
                }
                merged.snippets[i].shortcut = candidate
                shortcuts.insert(candidate)
            }
        }
        let survivingIDs = Set(merged.clips.map { CloudSyncState.id($0.id) })
        merged.payloads = merged.payloads.filter { survivingIDs.contains($0.key) }
        merged.usage = merged.usage.filter { survivingIDs.contains($0.key) }
        // Content is deterministic; no device name/current date churn on an idle sync.
        merged.updatedAt = merged.revisions.values.max() ?? max(local.updatedAt, remote.updatedAt)
        return merged
    }

    private func apply(_ state: CloudSyncState, in db: Database, obsoleteBlobs: inout [String], rollbackBlobs: inout [String]) throws -> Bool {
        let beforeClips = try ClipRecord.fetchAll(db)
        let beforeLists = try ClipListRecord.fetchAll(db)
        let beforeSnippets = try SnippetRecord.fetchAll(db)
        var changed = false
        let desired = Set(state.clips.map(\.id))
        // Includes dedup aliases and tombstones; incoming IDs are preserved exactly.
        let hashes = Dictionary(uniqueKeysWithValues: state.clips.map { ($0.id, $0.contentHash) })
        for clip in beforeClips where !desired.contains(clip.id) || hashes[clip.id] != clip.contentHash {
            obsoleteBlobs += try ClipPayloadRecord.filter(Column("clipId") == CloudSyncState.id(clip.id)).fetchAll(db)
                .compactMap(\.blobFilename)
            try ClipRecord.filter(Column("id") == CloudSyncState.id(clip.id)).deleteAll(db)
            changed = true
        }
        for list in state.lists where beforeLists.first(where: { $0.id == list.id }) != list {
            try list.save(db)
            changed = true
        }
        for clip in state.clips {
            let previous = try ClipRecord.filter(Column("id") == CloudSyncState.id(clip.id)).fetchOne(db)
            if previous != clip {
                try clip.save(db)
                changed = true
            }
            let representations = try ArchiveManager.validatedRepresentations(
                state.payloads[CloudSyncState.id(clip.id)] ?? [])
            let currentPayloads = try ClipPayloadRecord.filter(Column("clipId") == CloudSyncState.id(clip.id)).fetchAll(
                db)
            var current: [String: Data] = [:]
            for payload in currentPayloads {
                current[payload.utiType] = try databaseManager.loadPayloadData(for: payload)
            }
            if current != representations {
                rollbackBlobs += representations.values.filter { $0.count > 4096 }.map { CapturedClip.hash($0) + ".blob" }
                obsoleteBlobs += try databaseManager.replacePayloads(
                    clipId: clip.id, representations: representations, db: db)
                changed = true
            }
        }
        let listIDs = Set(state.lists.map(\.id))
        for list in beforeLists where !listIDs.contains(list.id) {
            try ClipListRecord.filter(Column("id") == CloudSyncState.id(list.id)).deleteAll(db)
            changed = true
        }
        // Avoid transient UNIQUE shortcut conflicts when two snippets swap their shortcuts.
        if beforeSnippets.sorted(by: { $0.id.uuidString < $1.id.uuidString }) != state.snippets {
            changed = true
            try SnippetRecord.deleteAll(db)
            for snippet in state.snippets { try snippet.insert(db) }
        }
        try SnippetRestoreOrigin.deleteAll(db)
        for origin in state.snippetOrigins { try origin.insert(db) }
        try db.execute(sql: "DELETE FROM sync_usage")
        for (id, components) in state.usage {
            for (device, count) in components {
                try db.execute(sql: "INSERT INTO sync_usage(clipId,deviceId,count) VALUES (?,?,?)",
                    arguments: [id, device, count])
            }
        }
        try db.execute(sql: "DELETE FROM sync_clip_metadata")
        for (id, fields) in state.metadataRevisions {
            for (field, date) in fields where ClipMetadataField(rawValue: field) != nil {
                try db.execute(sql: "INSERT INTO sync_clip_metadata(clipId,field,modifiedAt) VALUES (?,?,?)",
                    arguments: [id, field, date.timeIntervalSince1970])
            }
        }
        // Restore remote clocks after triggers; importing must not manufacture a newer local mutation.
        try db.execute(sql: "DELETE FROM sync_changes")
        for (key, date) in state.revisions {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let tombstones =
                parts[0] == "clip"
                ? state.tombstones : (parts[0] == "list" ? state.listTombstones : state.snippetTombstones)
            let deletion = tombstones[parts[1]]
            try db.execute(
                sql: "INSERT INTO sync_changes(kind,id,modifiedAt,deleted) VALUES (?,?,?,?)",
                arguments: [
                    parts[0], parts[1], max(date, deletion ?? .distantPast).timeIntervalSince1970,
                    deletion.map { $0 >= date } ?? false,
                ])
        }
        // v1 tombstones did not carry an independent revisions dictionary.
        for (kind, tombstones) in [
            ("clip", state.tombstones), ("list", state.listTombstones), ("snippet", state.snippetTombstones),
        ] {
            for (id, date) in tombstones where state.revisions[kind + ":" + id] == nil {
                try db.execute(
                    sql: "INSERT OR REPLACE INTO sync_changes(kind,id,modifiedAt,deleted) VALUES (?,?,?,1)",
                    arguments: [kind, id, date.timeIntervalSince1970])
            }
        }
        for (alias, canonical) in state.aliases {
            try db.execute(sql: "INSERT OR REPLACE INTO sync_aliases VALUES (?,?)", arguments: [alias, canonical])
        }
        return changed
    }
}

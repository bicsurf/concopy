import Foundation
import GRDB

public enum CloudSyncStatus: String, Sendable, Codable {
    case idle
    case syncing
    case unavailable
    case error
}

public struct CloudSyncState: Codable, Sendable {
    public var version: Int
    public var lastModifiedDeviceId: String
    public var updatedAt: Date
    public var clips: [ClipRecord]
    public var tombstones: [String: Date] // UUID string -> Deletion Date

    public init(
        version: Int = 1,
        lastModifiedDeviceId: String = "",
        updatedAt: Date = Date(),
        clips: [ClipRecord] = [],
        tombstones: [String: Date] = [:]
    ) {
        self.version = version
        self.lastModifiedDeviceId = lastModifiedDeviceId
        self.updatedAt = updatedAt
        self.clips = clips
        self.tombstones = tombstones
    }
}

public actor CloudDriveSyncWorker {
    public let syncDirectoryURL: URL
    public let syncFileURL: URL
    private let databaseManager: DatabaseManager
    private let fileManager = FileManager.default
    private let deviceId: String
    private var pendingTombstones: [String: Date] = [:]

    public init(
        databaseManager: DatabaseManager,
        customSyncDirectoryURL: URL? = nil,
        deviceId: String? = nil
    ) {
        self.databaseManager = databaseManager
        let baseDir = customSyncDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ConCopy", isDirectory: true)
        self.syncDirectoryURL = baseDir
        self.syncFileURL = baseDir.appendingPathComponent("sync-state-v1.json")
        self.deviceId = deviceId ?? (Host.current().localizedName ?? UUID().uuidString)
    }

    public func addTombstone(clipId: UUID) {
        pendingTombstones[clipId.uuidString.lowercased()] = Date()
    }

    public func isDriveAvailable() -> Bool {
        let parentDir = syncDirectoryURL.deletingLastPathComponent()
        return fileManager.fileExists(atPath: parentDir.path)
    }

    public func performSync() async -> (hasLocalChanges: Bool, status: CloudSyncStatus) {
        // 1. Fail-safe: check if parent directory (iCloud Drive root) exists
        guard isDriveAvailable() else {
            return (false, .unavailable)
        }

        do {
            // Ensure ConCopy directory exists
            if !fileManager.fileExists(atPath: syncDirectoryURL.path) {
                try fileManager.createDirectory(at: syncDirectoryURL, withIntermediateDirectories: true)
            }

            // 2. Non-blocking check: placeholder file .sync-state-v1.json.icloud
            let placeholderURL = syncDirectoryURL.appendingPathComponent(".sync-state-v1.json.icloud")
            if fileManager.fileExists(atPath: placeholderURL.path) {
                try? fileManager.startDownloadingUbiquitousItem(at: placeholderURL)
                return (false, .idle)
            }

            var remoteState: CloudSyncState? = nil
            if fileManager.fileExists(atPath: syncFileURL.path) {
                // Check ubiquitous download status if iCloud-managed
                if let values = try? syncFileURL.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
                   values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    try? fileManager.startDownloadingUbiquitousItem(at: syncFileURL)
                    return (false, .idle)
                }

                if let data = try? Data(contentsOf: syncFileURL) {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    remoteState = try? decoder.decode(CloudSyncState.self, from: data)
                }
            }

            var hasLocalChanges = false
            let localClips = (try? databaseManager.searchClips(query: "", limit: 1000)) ?? []

            var mergedTombstones = pendingTombstones
            if let remote = remoteState {
                for (id, date) in remote.tombstones {
                    mergedTombstones[id] = max(mergedTombstones[id] ?? date, date)
                }
            }

            // Prune tombstones older than 30 days
            let thirtyDaysAgo = Date().addingTimeInterval(-30 * 86400)
            mergedTombstones = mergedTombstones.filter { $0.value > thirtyDaysAgo }
            self.pendingTombstones = mergedTombstones

            // If remote state exists, reconcile tombstones and new clips
            if let remote = remoteState {
                // Delete local clips that have been deleted remotely
                for localClip in localClips {
                    let idStr = localClip.id.uuidString.lowercased()
                    if mergedTombstones[idStr] != nil {
                        try? databaseManager.deleteClip(clipId: localClip.id)
                        hasLocalChanges = true
                    }
                }

                // Ingest new remote clips
                for remoteClip in remote.clips {
                    let idStr = remoteClip.id.uuidString.lowercased()
                    if mergedTombstones[idStr] != nil {
                        continue
                    }

                    let existing = try? databaseManager.fetchClip(id: remoteClip.id)
                    if existing == nil {
                        let captured = CapturedClip(
                            plainText: remoteClip.plainText,
                            primaryType: remoteClip.primaryType,
                            sourceAppBundleId: remoteClip.sourceAppBundleId
                        )
                        if captured.plainText != nil || !captured.representations.isEmpty {
                            if let imported = try? databaseManager.ingestCapturedClip(captured) {
                                let customName = remoteClip.customName
                                let isFavorite = remoteClip.isFavorite
                                let updatedAt = remoteClip.updatedAt
                                let idString = imported.id.uuidString.lowercased()
                                try? await databaseManager.dbWriter.write { db in
                                    if var record = try? ClipRecord.filter(Column("id") == idString).fetchOne(db) {
                                        record.customName = customName
                                        record.isFavorite = isFavorite
                                        record.updatedAt = updatedAt
                                        try? record.update(db)
                                    }
                                }
                                hasLocalChanges = true
                            }
                        }
                    }
                }
            }

            // Fetch refreshed local clips after reconciliation
            let currentLocalClips = (try? databaseManager.searchClips(query: "", limit: 1000)) ?? []

            // Prepare merged state
            var allClipsMap: [UUID: ClipRecord] = [:]
            for clip in (remoteState?.clips ?? []) {
                let idStr = clip.id.uuidString.lowercased()
                if mergedTombstones[idStr] == nil {
                    allClipsMap[clip.id] = clip
                }
            }
            for clip in currentLocalClips {
                let idStr = clip.id.uuidString.lowercased()
                if mergedTombstones[idStr] == nil {
                    allClipsMap[clip.id] = clip
                }
            }

            let sortedClips = Array(allClipsMap.values)
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(1000)

            let newState = CloudSyncState(
                version: 1,
                lastModifiedDeviceId: self.deviceId,
                updatedAt: Date(),
                clips: Array(sortedClips),
                tombstones: mergedTombstones
            )

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encodedData = try encoder.encode(newState)

            // Fast atomic write
            try encodedData.write(to: syncFileURL, options: .atomic)

            return (hasLocalChanges, .idle)
        } catch {
            return (false, .idle)
        }
    }
}

import Foundation
import GRDB

public final class CloudKitSyncCoordinator: NSObject, @unchecked Sendable {
    public let databaseManager: DatabaseManager
    public var onRemoteChangesImported: (@MainActor () -> Void)?

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isRunning
    }

    public var isAvailable: Bool {
        Self.isCloudDriveAvailable
    }

    private var _isRunning: Bool = false
    private let worker: CloudDriveSyncWorker
    private let lock = NSLock()
    private var syncDebounceTask: Task<Void, Never>?

    public static var isCloudDriveAvailable: Bool {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        let cloudDocsURL = homeDir.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: cloudDocsURL.path)
    }

    public init(
        databaseManager: DatabaseManager,
        customSyncDirectoryURL: URL? = nil
    ) {
        self.databaseManager = databaseManager
        self.worker = CloudDriveSyncWorker(
            databaseManager: databaseManager,
            customSyncDirectoryURL: customSyncDirectoryURL
        )
        super.init()
    }

    /// Avvio non bloccante in 0ms (Fire-and-forget in background)
    public func startIfPossible() {
        lock.lock()
        guard !_isRunning else {
            lock.unlock()
            return
        }
        _isRunning = true
        lock.unlock()

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.performSync()
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        _isRunning = false
        syncDebounceTask?.cancel()
        syncDebounceTask = nil
    }

    // MARK: - Queueing Changes (Debounce 3 secondi)
    public func queueUpload(for clip: ClipRecord) {
        scheduleDebouncedSync()
    }

    public func queueUpload(for list: ClipListRecord) {
        scheduleDebouncedSync()
    }

    public func queueDeletion(clipId: UUID) {
        Task {
            await worker.addTombstone(clipId: clipId)
        }
        scheduleDebouncedSync()
    }

    public func scheduleDebouncedSync() {
        lock.lock()
        defer { lock.unlock() }

        syncDebounceTask?.cancel()
        syncDebounceTask = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.performSync()
        }
    }

    public func performSync() async {
        let (hasChanges, _) = await worker.performSync()
        if hasChanges {
            await MainActor.run {
                self.onRemoteChangesImported?()
            }
        }
    }
}

import Foundation
import GRDB

public final class CloudKitSyncCoordinator: NSObject, @unchecked Sendable {
    public let databaseManager: DatabaseManager
    public var onRemoteChangesImported: (@MainActor () -> Void)?
    public var onStatusChanged: (@MainActor (CloudSyncStatus) -> Void)?
    private let worker: CloudDriveSyncWorker
    private let lock = NSLock()
    private let observationQueue = DispatchQueue(label: "ConCopy.Sync.Changes")
    private var running = false
    private var generation: UInt64 = 0
    private var observation: (any DatabaseCancellable)?
    private var syncDebounceTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private let pollingInterval: TimeInterval
    private let debounceInterval: TimeInterval

    public var isRunning: Bool { lock.withLock { running } }
    public var isAvailable: Bool { Self.isCloudDriveAvailable }
    public static var isCloudDriveAvailable: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs").path)
    }
    public init(
        databaseManager: DatabaseManager, customSyncDirectoryURL: URL? = nil,
        pollingInterval: TimeInterval = 5, debounceInterval: TimeInterval = 3
    ) {
        self.databaseManager = databaseManager
        worker = CloudDriveSyncWorker(databaseManager: databaseManager, customSyncDirectoryURL: customSyncDirectoryURL)
        self.pollingInterval = max(0.05, pollingInterval)
        self.debounceInterval = max(0, debounceInterval)
        super.init()
    }
    deinit { stop() }

    public func startIfPossible() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        generation &+= 1
        let token = generation
        // Observe the journal, including changes from imports, cleanup and every UI mutation.
        observation = ValueObservation.tracking { db in
            try String.fetchOne(
                db,
                sql:
                    "SELECT group_concat(kind || id || printf('%.17g',modifiedAt) || deleted) FROM (SELECT * FROM sync_changes ORDER BY kind,id)"
            )
        }.removeDuplicates().start(
            in: databaseManager.dbWriter, scheduling: .async(onQueue: observationQueue),
            onError: { [weak self] _ in self?.publishStatus(.error) },
            onChange: { [weak self] _ in self?.scheduleDebouncedSync() })
        receiveTask = Task.detached(priority: .utility) { [weak self] in
            // Periodic receive also retries pending ubiquitous downloads, even with no local captures.
            while !Task.isCancelled {
                guard let self, self.isAuthorized(token) else { return }
                await self.performSync(token: token)
                do { try await Task.sleep(nanoseconds: UInt64(self.pollingInterval * 1_000_000_000)) } catch { return }
            }
        }
        lock.unlock()
    }
    public func stop() {
        lock.withLock {
            running = false
            generation &+= 1
            syncDebounceTask?.cancel()
            syncDebounceTask = nil
            receiveTask?.cancel()
            receiveTask = nil
            observation?.cancel()
            observation = nil
        }
    }
    private func isAuthorized(_ token: UInt64) -> Bool { lock.withLock { running && generation == token } }
    public func queueUpload(for clip: ClipRecord) { scheduleDebouncedSync() }
    public func queueUpload(for list: ClipListRecord) { scheduleDebouncedSync() }
    public func queueDeletion(clipId: UUID) {
        guard isRunning else { return }
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            try? await self.worker.addTombstone(clipId: clipId)
            self.scheduleDebouncedSync()
        }
    }
    public func scheduleDebouncedSync() {
        lock.withLock {
            guard running else { return }
            syncDebounceTask?.cancel()
            let token = generation
            let delay = debounceInterval
            syncDebounceTask = Task.detached(priority: .utility) { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                guard !Task.isCancelled, let self else { return }
                await self.performSync(token: token)
            }
        }
    }
    public func performSync() async {
        let token = lock.withLock { generation }
        await performSync(token: token, force: true)
    }
    private func performSync(token: UInt64, force: Bool = false) async {
        guard isAuthorized(token), !Task.isCancelled else { return }
        let result = await worker.performSync(force: force, isAuthorized: { [weak self] in self?.isAuthorized(token) == true })
        guard isAuthorized(token) else { return }
        await MainActor.run {
            self.onStatusChanged?(result.status)
            if result.hasLocalChanges { self.onRemoteChangesImported?() }
        }
    }
    private func publishStatus(_ status: CloudSyncStatus) {
        Task { @MainActor [weak self] in self?.onStatusChanged?(status) }
    }
}

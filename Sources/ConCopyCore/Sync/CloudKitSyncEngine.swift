import CloudKit
import Foundation
import GRDB

public protocol CloudKitSyncEngineDelegateProtocol: AnyObject, Sendable {
    func syncEngineDidUpdateRecords()
}

public final class CloudKitSyncCoordinator: NSObject, CKSyncEngineDelegate, @unchecked Sendable {
    public let databaseManager: DatabaseManager
    public let mapper: CloudKitRecordMapper
    public weak var delegate: CloudKitSyncEngineDelegateProtocol?

    private var syncEngine: CKSyncEngine?
    private let defaults: UserDefaults
    private let stateKey = "ConCopy.CloudKitSync.stateSerialization"
    private let lock = NSLock()

    private var pendingRecordIDsToSave: Set<CKRecord.ID> = []
    private var pendingRecordIDsToDelete: Set<CKRecord.ID> = []

    public init(
        databaseManager: DatabaseManager,
        userDefaults: UserDefaults = .standard,
        mapper: CloudKitRecordMapper = CloudKitRecordMapper()
    ) {
        self.databaseManager = databaseManager
        self.defaults = userDefaults
        self.mapper = mapper
        super.init()
    }

    public func startIfPossible(containerIdentifier: String? = nil) {
        lock.lock()
        defer { lock.unlock() }

        guard syncEngine == nil else { return }

        let container = containerIdentifier.map { CKContainer(identifier: $0) } ?? CKContainer.default()
        let database = container.privateCloudDatabase

        let stateSerialization: CKSyncEngine.State.Serialization?
        if let data = defaults.data(forKey: stateKey) {
            stateSerialization = try? PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: data)
        } else {
            stateSerialization = nil
        }

        let config = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: stateSerialization,
            delegate: self
        )

        self.syncEngine = CKSyncEngine(config)
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        syncEngine = nil
    }

    // MARK: - Queueing Changes
    public func queueUpload(for clip: ClipRecord) {
        let record = mapper.makeRecord(from: clip)
        lock.lock()
        defer { lock.unlock() }
        pendingRecordIDsToSave.insert(record.recordID)
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    public func queueUpload(for list: ClipListRecord) {
        let record = mapper.makeRecord(from: list)
        lock.lock()
        defer { lock.unlock() }
        pendingRecordIDsToSave.insert(record.recordID)
        syncEngine?.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
    }

    public func queueDeletion(for recordID: CKRecord.ID) {
        lock.lock()
        defer { lock.unlock() }
        pendingRecordIDsToDelete.insert(recordID)
        syncEngine?.state.add(pendingRecordZoneChanges: [.deleteRecord(recordID)])
    }

    // MARK: - CKSyncEngineDelegate
    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveStateSerialization(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let (recordsMap, changes) = collectPendingBatch()
        if changes.isEmpty {
            return nil
        }

        return await CKSyncEngine.RecordZoneChangeBatch(
            pendingChanges: changes,
            recordProvider: { recordID in
                recordsMap[recordID]
            }
        )
    }

    private func collectPendingBatch() -> ([CKRecord.ID: CKRecord], [CKSyncEngine.PendingRecordZoneChange]) {
        lock.lock()
        defer { lock.unlock() }

        var changes: [CKSyncEngine.PendingRecordZoneChange] = []
        var recordsMap: [CKRecord.ID: CKRecord] = [:]

        for recordID in pendingRecordIDsToSave {
            if recordID.zoneID == CloudKitRecordMapper.zoneID {
                if let uuid = UUID(uuidString: recordID.recordName) {
                    if let clip = try? databaseManager.fetchClip(id: uuid) {
                        recordsMap[recordID] = mapper.makeRecord(from: clip)
                        changes.append(.saveRecord(recordID))
                    } else if let list = try? databaseManager.fetchAllLists().first(where: { $0.id == uuid }) {
                        recordsMap[recordID] = mapper.makeRecord(from: list)
                        changes.append(.saveRecord(recordID))
                    }
                }
            }
        }

        for recordID in pendingRecordIDsToDelete {
            changes.append(.deleteRecord(recordID))
        }

        return (recordsMap, changes)
    }

    // MARK: - Internal Handlers
    private func saveStateSerialization(_ serialization: CKSyncEngine.State.Serialization) {
        if let data = try? PropertyListEncoder().encode(serialization) {
            defaults.set(data, forKey: stateKey)
        }
    }

    private func handleAccountChange(_ accountChange: CKSyncEngine.Event.AccountChange) {
        switch accountChange.changeType {
        case .signIn, .switchAccounts:
            print("[ConCopy] CloudKit Account Changed: reset sync engine state")
        case .signOut:
            print("[ConCopy] CloudKit Account Signed Out")
        @unknown default:
            break
        }
    }

    private func handleFetchedRecordZoneChanges(_ fetched: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in fetched.modifications {
            let record = modification.record
            if let clip = mapper.makeClip(from: record) {
                mergeIncomingClip(clip)
            } else if let list = mapper.makeList(from: record) {
                mergeIncomingList(list)
            }
        }

        for deletion in fetched.deletions {
            let recordID = deletion.recordID
            if let uuid = UUID(uuidString: recordID.recordName) {
                try? databaseManager.deleteClip(clipId: uuid)
            }
        }

        delegate?.syncEngineDidUpdateRecords()
    }

    private func handleSentRecordZoneChanges(_ sent: CKSyncEngine.Event.SentRecordZoneChanges) {
        lock.lock()
        defer { lock.unlock() }

        for savedRecord in sent.savedRecords {
            pendingRecordIDsToSave.remove(savedRecord.recordID)
        }
        for deletedID in sent.deletedRecordIDs {
            pendingRecordIDsToDelete.remove(deletedID)
        }
    }

    private func mergeIncomingClip(_ incoming: ClipRecord) {
        try? databaseManager.dbWriter.write { db in
            let existing = try ClipRecord.filter(Column("id") == incoming.id.uuidString.lowercased()).fetchOne(db)
            if var found = existing {
                if incoming.updatedAt > found.updatedAt {
                    found.plainText = incoming.plainText
                    found.customName = incoming.customName
                    found.isFavorite = incoming.isFavorite
                    found.listId = incoming.listId
                    found.updatedAt = incoming.updatedAt
                    try found.update(db)
                }
            } else {
                try incoming.insert(db)
            }
        }
    }

    private func mergeIncomingList(_ incoming: ClipListRecord) {
        try? databaseManager.dbWriter.write { db in
            let existing = try ClipListRecord.filter(Column("id") == incoming.id.uuidString.lowercased()).fetchOne(db)
            if var found = existing {
                found.name = incoming.name
                found.sortOrder = incoming.sortOrder
                found.isAutoStarActive = incoming.isAutoStarActive
                try found.update(db)
            } else {
                try incoming.insert(db)
            }
        }
    }
}

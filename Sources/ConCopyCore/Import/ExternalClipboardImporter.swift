import Foundation

public struct ImportErrorDetail: Sendable, Equatable {
    public let sourceIdentifier: String
    public let message: String

    public init(sourceIdentifier: String, message: String) {
        self.sourceIdentifier = sourceIdentifier
        self.message = message
    }
}

public struct ImportResult: Sendable, Equatable {
    public var importedCount: Int
    public var mergedDuplicatesCount: Int
    public var createdListsCount: Int
    public var errorsCount: Int
    public var errors: [ImportErrorDetail]

    public var isSuccess: Bool {
        errorsCount == 0
    }

    public init(
        importedCount: Int = 0,
        mergedDuplicatesCount: Int = 0,
        createdListsCount: Int = 0,
        errorsCount: Int = 0,
        errors: [ImportErrorDetail] = []
    ) {
        self.importedCount = importedCount
        self.mergedDuplicatesCount = mergedDuplicatesCount
        self.createdListsCount = createdListsCount
        self.errorsCount = errorsCount
        self.errors = errors
    }
}

public struct ImportProgress: Sendable, Equatable {
    public let processed: Int
    public let total: Int?
    public let imported: Int
    public let merged: Int

    public init(processed: Int, total: Int?, imported: Int, merged: Int) {
        self.processed = processed
        self.total = total
        self.imported = imported
        self.merged = merged
    }
}

public typealias ImportProgressHandler = @Sendable (ImportProgress) -> Void

public protocol ExternalClipboardImporter: Sendable {
    var displayName: String { get }
    func importClips(
        into databaseManager: DatabaseManager,
        progress: ImportProgressHandler?
    ) throws -> ImportResult
}

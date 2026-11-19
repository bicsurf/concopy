import Foundation

public struct DatabaseStartup: Sendable {
    public let database: DatabaseManager
    public let failureDescription: String?
    public var isTemporary: Bool { failureDescription != nil }

    /// A fallback owns its own blob directory: its GC must never inspect persistent assets.
    public static func open(diskDatabaseURL: URL, blobDirectoryURL: URL) throws -> DatabaseStartup {
        do {
            return DatabaseStartup(database: try DatabaseManager(
                diskDatabaseURL: diskDatabaseURL, blobDirectoryURL: blobDirectoryURL), failureDescription: nil)
        } catch {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("ConCopyRecovery-\(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent("blobs", isDirectory: true)
            return DatabaseStartup(database: try DatabaseManager(inMemoryWithBlobDirectoryURL: temporary),
                failureDescription: error.localizedDescription)
        }
    }
}

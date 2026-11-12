import Foundation
import GRDB

internal final class SourceDatabase {
    let queue: DatabaseQueue
    private let tempDirectoryURL: URL

    init(sourceFileURL: URL) throws {
        let resolvedURL = sourceFileURL.resolvingSymlinksInPath()
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("ConCopyImport_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        self.tempDirectoryURL = tempDir

        do {
            let baseName = resolvedURL.lastPathComponent
            let targetMainURL = tempDir.appendingPathComponent(baseName)

            let sourceDir = resolvedURL.deletingLastPathComponent()
            let sidecarExtensions = ["", "-wal", "-shm"]

            for ext in sidecarExtensions {
                let candidateSource = sourceDir.appendingPathComponent(baseName + ext)
                let candidateTarget = tempDir.appendingPathComponent(baseName + ext)
                if fileManager.fileExists(atPath: candidateSource.path) {
                    try fileManager.copyItem(at: candidateSource, to: candidateTarget)
                }
            }

            var config = Configuration()
            config.foreignKeysEnabled = false
            config.readonly = false

            self.queue = try DatabaseQueue(path: targetMainURL.path, configuration: config)
        } catch {
            try? fileManager.removeItem(at: tempDir)
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDirectoryURL)
    }
}

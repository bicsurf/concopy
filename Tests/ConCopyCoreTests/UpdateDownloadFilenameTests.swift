import Foundation
import Testing
@testable import ConCopyCore

struct UpdateDownloadFilenameTests {
    @Test func preservesVersionWithoutOverwritingDownloads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 0...2 {
            let source = directory.appendingPathComponent("temporary-download")
            let contents = Data("download-\(index)".utf8)
            try contents.write(to: source)
            let saved = try UpdateDownloader.saveDiskImage(at: source, version: "1.3.9", in: directory)
            let suffix = index == 0 ? "" : " (\(index))"
            #expect(saved.lastPathComponent == "ConCopy-1.3.9\(suffix).dmg")
            #expect(try Data(contentsOf: saved) == contents)
        }
        let original = directory.appendingPathComponent("ConCopy-1.3.9.dmg")
        #expect(try Data(contentsOf: original) == Data("download-0".utf8))
    }

    @Test(arguments: ["", "../../outside", "1.3/9", "1.3.9\\extra"])
    func rejectsUnsafeVersions(version: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("download")
        try Data("original".utf8).write(to: source)
        #expect(throws: UpdateDownloader.DownloadError.self) {
            try UpdateDownloader.saveDiskImage(at: source, version: version, in: directory)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["download"])
    }
}

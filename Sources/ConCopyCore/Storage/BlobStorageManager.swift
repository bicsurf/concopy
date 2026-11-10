import CryptoKit
import Foundation

public struct BlobStorageManager: Sendable {
    public let baseDirectoryURL: URL

    public static var defaultBaseDirectoryURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("ConCopy/blobs", isDirectory: true)
    }

    public init(baseDirectoryURL: URL = defaultBaseDirectoryURL) {
        self.baseDirectoryURL = baseDirectoryURL
    }

    @discardableResult
    public func storeBlob(data: Data) throws -> String {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: baseDirectoryURL.path) {
            try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
        }

        let digest = SHA256.hash(data: data)
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        let filename = "\(hashString).blob"
        let fileURL = baseDirectoryURL.appendingPathComponent(filename)

        if !fileManager.fileExists(atPath: fileURL.path) {
            try autoreleasepool {
                try data.write(to: fileURL, options: .atomic)
            }
        }

        return filename
    }

    public func loadBlob(filename: String) throws -> Data {
        let fileURL = baseDirectoryURL.appendingPathComponent(filename)
        return try autoreleasepool {
            try Data(contentsOf: fileURL, options: .mappedIfSafe)
        }
    }

    public func deleteBlobIfExists(filename: String) throws {
        let fileURL = baseDirectoryURL.appendingPathComponent(filename)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}

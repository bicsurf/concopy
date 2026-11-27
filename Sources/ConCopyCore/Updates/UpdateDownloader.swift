import Foundation

/// Streams the disk image to a temporary file; no release payload is held in memory.
public struct UpdateDownloader: Sendable {
    public init() {}

    public func download(from url: URL, version: String, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> URL {
        guard url.scheme?.lowercased() == "https", Self.isValidVersion(version) else { throw DownloadError.invalidResponse }
        let delegate = DownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              http.url?.scheme?.lowercased() == "https" else { throw DownloadError.invalidResponse }
        return try await Task.detached(priority: .utility) {
            try Self.validateDiskImage(at: temporaryURL, expectedLength: response.expectedContentLength)
            let downloads = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            return try Self.saveDiskImage(at: temporaryURL, version: version, in: downloads)
        }.value
    }

    private static func isValidVersion(_ version: String) -> Bool {
        !version.isEmpty && version.utf8.count <= 100 && version.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                || $0 == 46 || $0 == 45
        }
    }

    static func saveDiskImage(at source: URL, version: String, in directory: URL) throws -> URL {
        guard isValidVersion(version) else { throw DownloadError.invalidResponse }
        let basename = "ConCopy-\(version)"
        var suffix = 0
        while true {
            let name = suffix == 0 ? basename : "\(basename) (\(suffix))"
            let destination = directory.appendingPathComponent(name + ".dmg")
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists {
                suffix += 1
            }
        }
    }

    public static func validateDiskImage(at url: URL, expectedLength: Int64) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length >= 512, expectedLength <= 0 || length == UInt64(expectedLength) else {
            throw DownloadError.invalidDiskImage
        }
        try handle.seek(toOffset: length - 512)
        guard try handle.read(upToCount: 4) == Data("koly".utf8) else { throw DownloadError.invalidDiskImage }
    }

    public enum DownloadError: LocalizedError {
        case invalidResponse, invalidDiskImage
        public var errorDescription: String? {
            switch self {
            case .invalidResponse: return "The server did not return a valid update download."
            case .invalidDiskImage: return "The downloaded disk image is incomplete or invalid. Please try again."
            }
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64, Int64) -> Void
    init(progress: @escaping @Sendable (Int64, Int64) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }
}

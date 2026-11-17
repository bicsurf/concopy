import AppKit
import Foundation

public final class ScreenshotWatcher: @unchecked Sendable {
    public let monitoredDirectoryURL: URL
    public var onScreenshotCaptured: (@Sendable (CapturedClip, URL) -> Void)?

    private let queue = DispatchQueue(label: "com.local.ConCopy.ScreenshotWatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private struct FileStamp: Equatable {
        var size: UInt64
        var modified: Date
        var inode: UInt64
    }
    private var knownFiles: [String: FileStamp] = [:]
    private var pendingFiles: [String: FileStamp] = [:]
    private var processingFiles = Set<String>()
    private var retryScheduled = false
    private let lock = NSLock()
    private var isRunning: Bool = false
    private var captureEnabled = true
    public var isCaptureEnabled: Bool {
        get { lock.withLock { captureEnabled } }
        set { lock.withLock { captureEnabled = newValue } }
    }

    public func synchronizeMonitoringState() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isCaptureEnabled { self.start() } else { self.stop() }
        }
    }

    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff"]
    public static let screenshotBundleId = "com.apple.screencapture"

    public init(monitoredDirectoryURL: URL = ScreenshotWatcher.resolveDefaultScreenshotDirectory()) {
        self.monitoredDirectoryURL = monitoredDirectoryURL
    }

    deinit {
        stop()
    }

    public static func resolveDefaultScreenshotDirectory() -> URL {
        if let customLocation = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location") {
            let expanded = (customLocation as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: expanded)
            }
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        return desktop ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }

        guard !isRunning else { return }

        // Populate known files
        knownFiles = fetchCurrentFiles()
        pendingFiles.removeAll()

        let path = monitoredDirectoryURL.path
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            print("[ConCopy] ScreenshotWatcher: Unable to open directory for watching: \(path)")
            return
        }

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )

        src.setEventHandler { [weak self] in
            self?.checkForNewScreenshots()
        }

        let fd = fileDescriptor
        src.setCancelHandler { [weak self] in
            close(fd)
            if let self {
                self.lock.lock()
                self.fileDescriptor = -1
                self.lock.unlock()
            }
        }

        self.source = src
        self.isRunning = true
        src.resume()
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }

        guard isRunning else { return }
        isRunning = false

        if let src = source {
            src.cancel()
            self.source = nil
        } else if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
    }

    public func checkForNewScreenshots() {
        guard isCaptureEnabled else { return }
        let currentFiles = fetchCurrentFiles()

        lock.lock()
        knownFiles = knownFiles.filter { currentFiles[$0.key] != nil }
        pendingFiles = pendingFiles.filter { currentFiles[$0.key] != nil }
        let newFiles = currentFiles.filter {
            knownFiles[$0.key] != $0.value && pendingFiles[$0.key] != $0.value && !processingFiles.contains($0.key)
        }
        processingFiles.formUnion(newFiles.keys)
        lock.unlock()

        for (fileName, stamp) in newFiles {
            let fileURL = monitoredDirectoryURL.appendingPathComponent(fileName)
            defer { lock.withLock { _ = processingFiles.remove(fileName) } }
            guard isScreenshotFile(fileURL: fileURL) else {
                lock.withLock { knownFiles[fileName] = stamp }
                continue
            }
            // Wait for file write completion to prevent reading partial/empty file
            guard waitForFileStabilization(at: fileURL), isCaptureEnabled,
                let stableStamp = fileStamp(at: fileURL), let clip = processFile(at: fileURL),
                stableStamp == fileStamp(at: fileURL), isCaptureEnabled else {
                lock.withLock { pendingFiles[fileName] = stamp }
                continue
            }
            lock.withLock {
                knownFiles[fileName] = stableStamp
                pendingFiles.removeValue(forKey: fileName)
            }
            onScreenshotCaptured?(clip, fileURL)
        }
        schedulePendingRetry()
    }

    private func schedulePendingRetry() {
        let schedule = lock.withLock { () -> Bool in
            guard isRunning, captureEnabled, !pendingFiles.isEmpty, !retryScheduled else { return false }
            retryScheduled = true
            return true
        }
        guard schedule else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let running = self.lock.withLock { self.retryScheduled = false; return self.isRunning }
            if running { self.checkForNewScreenshots() }
        }
    }

    private func waitForFileStabilization(at url: URL, maxRetries: Int = 5, retryDelay: TimeInterval = 0.04) -> Bool {
        // Initial debounce for macOS screenshot write flush
        Thread.sleep(forTimeInterval: 0.15)
        var previousSize: Int64 = -1

        for _ in 0..<maxRetries {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? Int64,
                size > 0
            else {
                Thread.sleep(forTimeInterval: retryDelay)
                continue
            }

            if size == previousSize {
                return true
            }
            previousSize = size
            Thread.sleep(forTimeInterval: retryDelay)
        }

        return previousSize > 0
    }

    public func processFile(at fileURL: URL) -> CapturedClip? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }

        return autoreleasepool {
            // Ensure file is readable and non-empty
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
                return nil
            }

            // Verify valid image representation
            guard let image = CompleteImageDecoder.decode(data) else {
                return nil
            }

            var representations: [String: Data] = [:]

            // Store standard PNG representation
            if CompleteImageDecoder.isPNG(data) {
                representations["public.png"] = data
            } else if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                representations["public.png"] = png
            } else {
                return nil
            }

            // Store file-url representation
            representations["public.file-url"] = fileURL.dataRepresentation

            let clip = CapturedClip(
                plainText: fileURL.lastPathComponent,
                primaryType: .image,
                sourceAppBundleId: Self.screenshotBundleId,
                representations: representations
            )

            return clip
        }
    }

    public func isScreenshotFile(fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { return false }

        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        // Common macOS screenshot naming conventions across languages
        let patterns = [
            "screenshot", "schermata", "capture", "captura", "screen shot",
            "bildschirmfoto", "skjermbilde", "kuvankaappaus",
        ]

        return patterns.contains { name.hasPrefix($0) || name.contains($0) }
    }

    private func fileStamp(at url: URL) -> FileStamp? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? NSNumber, let modified = attrs[.modificationDate] as? Date,
            let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        return FileStamp(size: size.uint64Value, modified: modified, inode: inode.uint64Value)
    }

    private func fetchCurrentFiles() -> [String: FileStamp] {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: monitoredDirectoryURL.path)) ?? []
        return Dictionary(items.compactMap { name in
            fileStamp(at: monitoredDirectoryURL.appendingPathComponent(name)).map { (name, $0) }
        }, uniquingKeysWith: { _, latest in latest })
    }
}

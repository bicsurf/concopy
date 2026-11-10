import AppKit
import Foundation

public final class ScreenshotWatcher: @unchecked Sendable {
    public let monitoredDirectoryURL: URL
    public var onScreenshotCaptured: (@Sendable (CapturedClip, URL) -> Void)?

    private let queue = DispatchQueue(label: "com.local.ConCopy.ScreenshotWatcher", qos: .utility)
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var knownFiles: Set<String> = []
    private let lock = NSLock()
    private var isRunning: Bool = false

    public static let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff"]

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
        knownFiles = fetchCurrentFileNames()

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

        src.setCancelHandler { [weak self] in
            guard let self = self else { return }
            if self.fileDescriptor >= 0 {
                close(self.fileDescriptor)
                self.fileDescriptor = -1
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
        }
    }

    public func checkForNewScreenshots() {
        let currentFiles = fetchCurrentFileNames()

        lock.lock()
        let newFiles = currentFiles.subtracting(knownFiles)
        knownFiles.formUnion(newFiles)
        lock.unlock()

        for fileName in newFiles {
            let fileURL = monitoredDirectoryURL.appendingPathComponent(fileName)
            guard isScreenshotFile(fileURL: fileURL) else { continue }
            // Wait for file write completion to prevent reading partial/empty file
            guard waitForFileStabilization(at: fileURL) else { continue }
            if let clip = processFile(at: fileURL) {
                onScreenshotCaptured?(clip, fileURL)
            }
        }
    }

    private func waitForFileStabilization(at url: URL, maxRetries: Int = 5, retryDelay: TimeInterval = 0.04) -> Bool {
        // Initial debounce for macOS screenshot write flush
        Thread.sleep(forTimeInterval: 0.15)
        var previousSize: Int64 = -1

        for _ in 0..<maxRetries {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64,
                  size > 0 else {
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

        // Ensure file is readable and non-empty
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return nil
        }

        // Verify valid image representation
        guard let image = NSImage(data: data) else {
            return nil
        }

        var representations: [String: Data] = [:]

        // Store standard PNG representation
        if fileURL.pathExtension.lowercased() == "png" {
            representations["public.png"] = data
        } else if let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let png = bitmap.representation(using: .png, properties: [:]) {
            representations["public.png"] = png
        } else {
            representations["public.png"] = data
        }

        // Store file-url representation
        representations["public.file-url"] = fileURL.dataRepresentation

        let clip = CapturedClip(
            plainText: fileURL.lastPathComponent,
            primaryType: .image,
            sourceAppBundleId: "com.apple.screencapture",
            representations: representations
        )

        return clip
    }

    public func isScreenshotFile(fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension.lowercased()
        guard Self.supportedExtensions.contains(ext) else { return false }

        let name = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        // Common macOS screenshot naming conventions across languages
        let patterns = [
            "screenshot", "schermata", "capture", "captura", "screen shot",
            "bildschirmfoto", "skjermbilde", "kuvankaappaus"
        ]

        return patterns.contains { name.hasPrefix($0) || name.contains($0) }
    }

    private func fetchCurrentFileNames() -> Set<String> {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: monitoredDirectoryURL.path)) ?? []
        return Set(items)
    }
}

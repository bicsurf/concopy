import AppKit
import ApplicationServices
import ConCopyCore
import ConCopyUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItemController: StatusItemController?
    private var clipboardMonitor: ClipboardMonitor?
    private var screenshotWatcher: ScreenshotWatcher?
    private var syncCoordinator: CloudKitSyncCoordinator?
    private var databaseManager: DatabaseManager?
    private var viewModel: ClipboardViewModel?

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        _ = checkAccessibilityPermissions()

        let db: DatabaseManager
        do {
            db = try setupDatabase()
        } catch {
            print("[ConCopy] Failed to initialize database: \(error)")
            return
        }
        self.databaseManager = db

        let vm = ClipboardViewModel(databaseManager: db)
        self.viewModel = vm

        let floatingPanel = FloatingPanel(viewModel: vm)
        self.panel = floatingPanel

        self.statusItemController = StatusItemController(panel: floatingPanel)

        KeyboardShortcuts.onKeyUp(for: .toggleConCopyPanel) { [weak floatingPanel] in
            floatingPanel?.togglePanel()
        }

        let monitor = ClipboardMonitor()
        monitor.onNewCapturedClip = { [weak self] captured in
            do {
                let saved = try self?.databaseManager?.ingestCapturedClip(captured)
                if let clip = saved {
                    self?.syncCoordinator?.queueUpload(for: clip)
                }
                self?.viewModel?.loadClips()
            } catch {
                print("[ConCopy] Error ingesting captured clip: \(error)")
            }
        }
        monitor.start()
        self.clipboardMonitor = monitor

        // Setup ScreenshotWatcher
        let watcher = ScreenshotWatcher()
        watcher.onScreenshotCaptured = { [weak self] clip, fileURL in
            Task { @MainActor [weak self] in
                guard AppSettingsManager.shared.autoCaptureScreenshots else { return }
                do {
                    let saved = try self?.databaseManager?.ingestCapturedClip(clip)
                    if let clip = saved {
                        self?.syncCoordinator?.queueUpload(for: clip)
                    }
                    self?.viewModel?.loadClips()
                } catch {
                    print("[ConCopy] Error ingesting screenshot: \(error)")
                }
            }
        }
        watcher.start()
        self.screenshotWatcher = watcher

        // Setup CloudKit Sync Coordinator
        let sync = CloudKitSyncCoordinator(databaseManager: db)
        if AppSettingsManager.shared.iCloudSyncEnabled {
            sync.startIfPossible()
        }
        self.syncCoordinator = sync

        // Background Auto-cleanup
        if AppSettingsManager.shared.autoCleanupEnabled {
            let retentionDays = AppSettingsManager.shared.retentionDays
            let maxCount = AppSettingsManager.shared.maxHistoryCount
            Task.detached(priority: .background) {
                let pruned = (try? db.pruneClips(olderThanDays: retentionDays, maxCount: maxCount)) ?? 0
                if pruned > 0 {
                    print("[ConCopy] Auto-cleanup pruned \(pruned) expired clips")
                    await MainActor.run { [weak self] in
                        self?.viewModel?.loadClips()
                    }
                }
            }
        }
    }

    private func setupDatabase() throws -> DatabaseManager {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dbDirectory = appSupport.appendingPathComponent("ConCopy", isDirectory: true)
        let dbURL = dbDirectory.appendingPathComponent("concopy.sqlite")
        let blobsURL = dbDirectory.appendingPathComponent("blobs", isDirectory: true)

        do {
            return try DatabaseManager(diskDatabaseURL: dbURL, blobDirectoryURL: blobsURL)
        } catch {
            print("[ConCopy] Failed to open disk database, falling back to memory: \(error)")
            return try DatabaseManager(inMemoryWithBlobDirectoryURL: blobsURL)
        }
    }

    @discardableResult
    private func checkAccessibilityPermissions(prompt: Bool = true) -> Bool {
        let checkOptionPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        let options = [checkOptionPrompt: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

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
    private let linkMetadataFetcher = LinkMetadataFetcher()

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AboutWindowController.loadConCopyAppIcon()

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

        PreferencesWindowController.shared.configure(databaseManager: db) { [weak vm] in
            vm?.loadClips()
        }

        let floatingPanel = FloatingPanel(viewModel: vm)
        floatingPanel.onOpenSettings = {
            PreferencesWindowController.shared.showWindow()
        }
        vm.onOpenSettings = {
            PreferencesWindowController.shared.showWindow()
        }
        self.panel = floatingPanel

        let statusController = StatusItemController(panel: floatingPanel)
        if let button = statusController.statusButton {
            button.image = MenuBarIcon.create()
            button.imagePosition = .imageOnly
            button.toolTip = "ConCopy"
        }
        self.statusItemController = statusController

        // Auto-check for updates if enabled
        Task {
            await UpdateChecker.shared.checkAutomaticallyIfNeeded()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleConCopyPanel) { [weak floatingPanel] in
            floatingPanel?.togglePanel()
        }

        let monitor = ClipboardMonitor()
        monitor.onNewCapturedClip = { [weak self] captured in
            guard let self else { return }
            let db = self.databaseManager
            let fetcher = self.linkMetadataFetcher
            let sync = self.syncCoordinator
            let vm = self.viewModel

            Task.detached(priority: .utility) {
                do {
                    let saved = try db?.ingestCapturedClip(captured)
                    if let clip = saved {
                        sync?.queueUpload(for: clip)
                        if clip.primaryType == .url,
                           let plain = clip.plainText,
                           let url = URL(string: plain),
                           let db {
                            Task {
                                await fetcher.fetchAndUpdateMetadata(clipId: clip.id, url: url, databaseManager: db)
                                await MainActor.run {
                                    vm?.loadClips()
                                }
                            }
                        }
                    }
                    await MainActor.run {
                        vm?.loadClips()
                    }
                } catch {
                    print("[ConCopy] Error ingesting captured clip: \(error)")
                }
            }
        }
        monitor.start()
        self.clipboardMonitor = monitor

        // Setup ScreenshotWatcher
        let watcher = ScreenshotWatcher()
        watcher.onScreenshotCaptured = { [weak self] clip, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard AppSettingsManager.shared.autoCaptureScreenshots else { return }
                let db = self.databaseManager
                let sync = self.syncCoordinator
                let vm = self.viewModel

                Task.detached(priority: .utility) {
                    do {
                        let saved = try db?.ingestCapturedClip(clip)
                        if let clip = saved {
                            sync?.queueUpload(for: clip)
                        }
                        await MainActor.run {
                            vm?.loadClips()
                        }
                    } catch {
                        print("[ConCopy] Error ingesting screenshot: \(error)")
                    }
                }
            }
        }
        watcher.start()
        self.screenshotWatcher = watcher

        // Setup iCloud Drive Sync Coordinator
        let sync = CloudKitSyncCoordinator(databaseManager: db)
        sync.onRemoteChangesImported = { [weak vm] in
            vm?.loadClips()
        }
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

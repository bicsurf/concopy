import AppKit
import ApplicationServices
import Combine
import ConCopyCore
import ConCopyUI
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: FloatingPanel?
    private var statusItemController: StatusItemController?
    private var clipboardMonitor: ClipboardMonitor?
    private var screenshotWatcher: ScreenshotWatcher?
    private var syncCoordinator: CloudDriveSyncCoordinator?
    private var databaseManager: DatabaseManager?
    private var viewModel: ClipboardViewModel?
    private var settingsObservers = Set<AnyCancellable>()
    private var cleanupTimer: Timer?
    private var cleanupTask: Task<Void, Never>?

    nonisolated override init() {
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = AboutWindowController.loadConCopyAppIcon()

        _ = checkAccessibilityPermissions()

        Task { [weak self] in
            do {
                let startup = try await Task.detached(priority: .userInitiated) { try Self.setupDatabase() }.value
                self?.configure(database: startup.database, isTemporary: startup.isTemporary)
                if let reason = startup.failureDescription { ConCopyLogger.storage.error("Temporary history: \(reason, privacy: .private)") }
            } catch { ConCopyLogger.storage.error("Failed to initialize database: \(error, privacy: .private)") }
        }
    }

    private func configure(database db: DatabaseManager, isTemporary: Bool) {
        self.databaseManager = db

        let vm = ClipboardViewModel(databaseManager: db)
        vm.isHistoryTemporary = isTemporary
        self.viewModel = vm

        PreferencesWindowController.shared.configure(databaseManager: db) { [weak vm] in
            vm?.loadLists()
            vm?.loadClips()
            vm?.loadSnippets()
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
            button.toolTip = isTemporary ? "ConCopy — Temporary history" : "ConCopy"
        }
        self.statusItemController = statusController

        UpdateDownloadController.shared.onReadyToInstall = { NSApp.terminate(nil) }

        // Auto-check for updates if enabled
        UpdateChecker.shared.startAutomaticChecks()

        KeyboardShortcuts.onKeyUp(for: .toggleConCopyPanel) { [weak floatingPanel] in
            floatingPanel?.togglePanel()
        }

        KeyboardShortcuts.onKeyUp(for: .pasteNextFromQueue) { [weak self] in
            self?.viewModel?.pasteNextFromQueue()
        }

        let monitor = ClipboardMonitor()
        monitor.onNewCapturedClip = { [weak self] captured in
            guard let self else { return }
            let db = self.databaseManager
            let sync = self.syncCoordinator
            let vm = self.viewModel

            let expirationMinutes = AppSettingsManager.shared.sensitiveClipExpirationMinutes
            Task.detached(priority: .utility) {
                do {
                    let saved = try db?.ingestCapturedClip(captured.recognizingImageText(), expirationMinutes: expirationMinutes)
                    if let clip = saved {
                        sync?.queueUpload(for: clip)
                    }
                    await MainActor.run {
                        vm?.loadClips()
                        self.scheduleCleanup()
                    }
                } catch {
                    ConCopyLogger.storage.error("Error ingesting captured clip: \(error.localizedDescription, privacy: .private)")
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
                guard AppSettingsManager.shared.shouldCaptureScreenshots else { return }
                let db = self.databaseManager
                let sync = self.syncCoordinator
                let vm = self.viewModel

                let expirationMinutes = AppSettingsManager.shared.sensitiveClipExpirationMinutes
                Task.detached(priority: .utility) {
                    do {
                        let saved = try db?.ingestCapturedClip(clip.recognizingImageText(), expirationMinutes: expirationMinutes)
                        if let savedClip = saved {
                            sync?.queueUpload(for: savedClip)
                        }
                        await MainActor.run {
                            vm?.loadClips()
                            self.scheduleCleanup()
                        }
                    } catch {
                        ConCopyLogger.storage.error("Error ingesting screenshot: \(error.localizedDescription, privacy: .private)")
                    }
                }
            }
        }
        self.screenshotWatcher = watcher
        let settings = AppSettingsManager.shared
        settings.$isMonitoringPaused.combineLatest(settings.$autoCaptureScreenshots, settings.$excludedAppBundleIds)
            .receive(on: DispatchQueue.main)
            .sink { [weak watcher] _ in
                guard let watcher else { return }
                let enabled = settings.shouldCaptureScreenshots
                watcher.isCaptureEnabled = enabled
                watcher.synchronizeMonitoringState()
            }.store(in: &settingsObservers)

        // Setup iCloud Drive Sync Coordinator
        let sync = CloudDriveSyncCoordinator(databaseManager: db)
        sync.onRemoteChangesImported = { [weak vm] in
            vm?.loadLists()
            vm?.loadClips()
            vm?.loadSnippets()
        }
        sync.onStatusChanged = { [weak vm] status in vm?.cloudSyncStatus = status }
        vm.onRetrySync = { [weak sync] in Task { await sync?.performSync() } }
        settings.$iCloudSyncEnabled.removeDuplicates().sink { [weak sync] enabled in
            if enabled && !isTemporary { sync?.startIfPossible() } else { sync?.stop() }
        }.store(in: &settingsObservers)
        self.syncCoordinator = sync

        // Retention and expired sensitive clips cleanup runs at launch, after captures, periodically, and when policy changes.
        settings.$autoCleanupEnabled.combineLatest(settings.$retentionDays, settings.$maxHistoryCount, settings.$sensitiveClipExpirationMinutes)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.scheduleCleanup() }
            .store(in: &settingsObservers)
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scheduleCleanup() }
        }
        scheduleCleanup()
    }

    private func scheduleCleanup() {
        guard let db = databaseManager, viewModel?.isHistoryTemporary == false else { return }
        let settings = AppSettingsManager.shared
        let policy = HistoryRetentionPolicy(
            enabled: settings.autoCleanupEnabled, days: settings.retentionDays, maxCount: settings.maxHistoryCount)
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 500_000_000)
                let expiredCount = try await Task.detached(priority: .utility) { try db.cleanupExpiredClips() }.value
                let retentionCount = try await Task.detached(priority: .utility) { try policy.apply(to: db) }.value
                if expiredCount > 0 || retentionCount > 0 { self?.viewModel?.loadClips() }
            } catch is CancellationError {} catch { ConCopyLogger.storage.error("Cleanup failed: \(error, privacy: .private)") }
        }
    }

    nonisolated private static func setupDatabase() throws -> DatabaseStartup {
        let appSupport =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dbDirectory = appSupport.appendingPathComponent("ConCopy", isDirectory: true)
        let dbURL = dbDirectory.appendingPathComponent("concopy.sqlite")
        let blobsURL = dbDirectory.appendingPathComponent("blobs", isDirectory: true)

        return try DatabaseStartup.open(diskDatabaseURL: dbURL, blobDirectoryURL: blobsURL)
    }

    @discardableResult
    private func checkAccessibilityPermissions(prompt: Bool = true) -> Bool {
        let checkOptionPrompt = "AXTrustedCheckOptionPrompt" as NSString
        let options = [checkOptionPrompt: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !AppSettingsManager.shared.showMenuBarIcon {
            AppSettingsManager.shared.showMenuBarIcon = true
        }
        panel?.showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        screenshotWatcher?.stop()
        syncCoordinator?.stop()
        UpdateChecker.shared.stopAutomaticChecks()
        cleanupTimer?.invalidate()
        cleanupTask?.cancel()
        settingsObservers.removeAll()
    }
}

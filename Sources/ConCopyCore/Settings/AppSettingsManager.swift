import Foundation
import ServiceManagement

@MainActor
public final class AppSettingsManager: ObservableObject {
    public static let shared = AppSettingsManager()

    public static let monitoringPausedKey = "ConCopy.Settings.isMonitoringPaused"
    public static let excludedAppBundleIdsKey = "ConCopy.Settings.excludedAppBundleIds"
    public static let launchAtLoginKey = "ConCopy.Settings.launchAtLogin"
    public static let autoCleanupEnabledKey = "ConCopy.Settings.autoCleanupEnabled"
    public static let retentionDaysKey = "ConCopy.Settings.retentionDays"
    public static let maxHistoryCountKey = "ConCopy.Settings.maxHistoryCount"
    public static let autoCaptureScreenshotsKey = "ConCopy.Settings.autoCaptureScreenshots"
    public static let iCloudSyncEnabledKey = "ConCopy.Settings.iCloudSyncEnabled"

    public static let defaultExcludedAppBundleIds: [String] = [
        "com.agilebits.onepassword",
        "com.apple.keychainaccess"
    ]

    private let defaults: UserDefaults

    @Published public var isMonitoringPaused: Bool {
        didSet {
            defaults.set(isMonitoringPaused, forKey: Self.monitoringPausedKey)
        }
    }

    @Published public var excludedAppBundleIds: [String] {
        didSet {
            defaults.set(excludedAppBundleIds, forKey: Self.excludedAppBundleIdsKey)
        }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Self.launchAtLoginKey)
            updateLaunchAtLoginService(enabled: launchAtLogin)
        }
    }

    @Published public var autoCleanupEnabled: Bool {
        didSet {
            defaults.set(autoCleanupEnabled, forKey: Self.autoCleanupEnabledKey)
        }
    }

    @Published public var retentionDays: Int {
        didSet {
            defaults.set(retentionDays, forKey: Self.retentionDaysKey)
        }
    }

    @Published public var maxHistoryCount: Int {
        didSet {
            defaults.set(maxHistoryCount, forKey: Self.maxHistoryCountKey)
        }
    }

    @Published public var autoCaptureScreenshots: Bool {
        didSet {
            defaults.set(autoCaptureScreenshots, forKey: Self.autoCaptureScreenshotsKey)
        }
    }

    @Published public var iCloudSyncEnabled: Bool {
        didSet {
            defaults.set(iCloudSyncEnabled, forKey: Self.iCloudSyncEnabledKey)
        }
    }

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults

        let paused = userDefaults.bool(forKey: Self.monitoringPausedKey)
        self.isMonitoringPaused = paused

        if let existing = userDefaults.stringArray(forKey: Self.excludedAppBundleIdsKey) {
            self.excludedAppBundleIds = existing
        } else {
            self.excludedAppBundleIds = Self.defaultExcludedAppBundleIds
            userDefaults.set(Self.defaultExcludedAppBundleIds, forKey: Self.excludedAppBundleIdsKey)
        }

        if #available(macOS 13.0, *) {
            let isBundled = Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
            let isEnabled = isBundled && (SMAppService.mainApp.status == .enabled)
            self.launchAtLogin = isEnabled || userDefaults.bool(forKey: Self.launchAtLoginKey)
        } else {
            self.launchAtLogin = userDefaults.bool(forKey: Self.launchAtLoginKey)
        }

        if userDefaults.object(forKey: Self.autoCleanupEnabledKey) != nil {
            self.autoCleanupEnabled = userDefaults.bool(forKey: Self.autoCleanupEnabledKey)
        } else {
            self.autoCleanupEnabled = true
        }

        let savedDays = userDefaults.integer(forKey: Self.retentionDaysKey)
        self.retentionDays = savedDays > 0 ? savedDays : 30

        let savedMaxCount = userDefaults.integer(forKey: Self.maxHistoryCountKey)
        self.maxHistoryCount = savedMaxCount > 0 ? savedMaxCount : 1000

        if userDefaults.object(forKey: Self.autoCaptureScreenshotsKey) != nil {
            self.autoCaptureScreenshots = userDefaults.bool(forKey: Self.autoCaptureScreenshotsKey)
        } else {
            self.autoCaptureScreenshots = true
        }

        self.iCloudSyncEnabled = userDefaults.bool(forKey: Self.iCloudSyncEnabledKey)
    }

    public func isAppExcluded(bundleId: String?) -> Bool {
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines), !bundleId.isEmpty else {
            return false
        }
        return excludedAppBundleIds.contains {
            $0.caseInsensitiveCompare(bundleId) == .orderedSame
        }
    }

    public func addExcludedApp(bundleId: String) {
        let cleaned = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        if !excludedAppBundleIds.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
            excludedAppBundleIds.append(cleaned)
        }
    }

    public func removeExcludedApp(bundleId: String) {
        let cleaned = bundleId.trimmingCharacters(in: .whitespacesAndNewlines)
        excludedAppBundleIds.removeAll {
            $0.caseInsensitiveCompare(cleaned) == .orderedSame
        }
    }

    public func toggleMonitoringPaused() {
        isMonitoringPaused.toggle()
    }

    private func updateLaunchAtLoginService(enabled: Bool) {
        guard Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") else {
            return
        }
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                // Fails in test environments or non-bundled CLI executions
            }
        }
    }
}

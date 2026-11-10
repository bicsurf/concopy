import AppKit
import XCTest
@testable import ConCopyCore

final class PreferencesTests: XCTestCase {
    private var testDefaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "ConCopyPreferencesTests_\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let name = suiteName {
            testDefaults?.removePersistentDomain(forName: name)
        }
        testDefaults = nil
        try super.tearDownWithError()
    }

    @MainActor
    func testAddAndRemoveBlacklist() {
        let settings = AppSettingsManager(userDefaults: testDefaults)

        // Verify initial state
        XCTAssertFalse(settings.isAppExcluded(bundleId: "com.test.CustomApp"))
        XCTAssertFalse(settings.isAppExcluded(bundleId: nil))
        XCTAssertFalse(settings.isAppExcluded(bundleId: "   "))

        // Add to blacklist
        settings.addExcludedApp(bundleId: "com.test.CustomApp")
        XCTAssertTrue(settings.isAppExcluded(bundleId: "com.test.CustomApp"))
        XCTAssertTrue(settings.isAppExcluded(bundleId: "COM.TEST.CUSTOMAPP")) // Case insensitive
        XCTAssertTrue(settings.isAppExcluded(bundleId: " com.test.CustomApp "))
        XCTAssertTrue(settings.excludedAppBundleIds.contains("com.test.CustomApp"))

        // Duplicate addition should be ignored
        settings.addExcludedApp(bundleId: "com.test.CustomApp")
        let count = settings.excludedAppBundleIds.filter { $0.caseInsensitiveCompare("com.test.CustomApp") == .orderedSame }.count
        XCTAssertEqual(count, 1)

        // Remove from blacklist
        settings.removeExcludedApp(bundleId: "com.test.CustomApp")
        XCTAssertFalse(settings.isAppExcluded(bundleId: "com.test.CustomApp"))
        XCTAssertFalse(settings.excludedAppBundleIds.contains("com.test.CustomApp"))
    }

    @MainActor
    func testMonitoringPauseStopsClipboardMonitor() {
        let pasteboard = NSPasteboard.withUniqueName()
        let settings = AppSettingsManager(userDefaults: testDefaults)
        settings.isMonitoringPaused = true

        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            settingsManager: settings
        )

        pasteboard.clearContents()
        pasteboard.setString("Confidential While Paused", forType: .string)

        let resultWhilePaused = monitor.checkForChanges()
        XCTAssertNil(resultWhilePaused, "Monitor must not capture clips when paused")

        // Unpause and verify capture resumes
        settings.isMonitoringPaused = false

        pasteboard.clearContents()
        pasteboard.setString("Allowed After Unpause", forType: .string)

        let resultAfterUnpause = monitor.checkForChanges()
        XCTAssertNotNil(resultAfterUnpause, "Monitor must capture clips when unpaused")
        XCTAssertEqual(resultAfterUnpause?.content, "Allowed After Unpause")
    }

    @MainActor
    func testBlacklistFiltersClipboardMonitor() {
        let pasteboard = NSPasteboard.withUniqueName()
        let settings = AppSettingsManager(userDefaults: testDefaults)
        settings.isMonitoringPaused = false
        settings.addExcludedApp(bundleId: "com.secret.vault")

        var simulatedApp = "com.secret.vault"
        let monitor = ClipboardMonitor(
            pasteboard: pasteboard,
            settingsManager: settings,
            frontmostAppBundleIdProvider: { simulatedApp }
        )

        // Attempt capture from blacklisted app
        pasteboard.clearContents()
        pasteboard.setString("Secret Password from Vault", forType: .string)

        let resultFromBlacklist = monitor.checkForChanges()
        XCTAssertNil(resultFromBlacklist, "ClipboardMonitor must discard clips copied from blacklisted apps")

        // Switch to an allowed app
        simulatedApp = "com.apple.Safari"
        pasteboard.clearContents()
        pasteboard.setString("https://developer.apple.com", forType: .string)

        let resultFromAllowed = monitor.checkForChanges()
        XCTAssertNotNil(resultFromAllowed, "ClipboardMonitor must capture clips copied from allowed apps")
        XCTAssertEqual(resultFromAllowed?.content, "https://developer.apple.com")
    }

    @MainActor
    func testDirectPastePreferenceDefaultAndPersistence() {
        let settings = AppSettingsManager(userDefaults: testDefaults)
        // Default must be true
        XCTAssertTrue(settings.isDirectPasteEnabled)

        // Toggle to false and verify persistence
        settings.isDirectPasteEnabled = false
        XCTAssertFalse(settings.isDirectPasteEnabled)
        XCTAssertFalse(testDefaults.bool(forKey: AppSettingsManager.isDirectPasteEnabledKey))

        // Recreate manager with same defaults
        let reloaded = AppSettingsManager(userDefaults: testDefaults)
        XCTAssertFalse(reloaded.isDirectPasteEnabled)

        // Reset to true
        reloaded.isDirectPasteEnabled = true
        XCTAssertTrue(reloaded.isDirectPasteEnabled)
        XCTAssertTrue(testDefaults.bool(forKey: AppSettingsManager.isDirectPasteEnabledKey))
    }
}

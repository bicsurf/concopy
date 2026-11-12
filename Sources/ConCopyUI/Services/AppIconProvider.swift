import AppKit
import Foundation

@MainActor
public final class AppIconProvider {
    public static let shared = AppIconProvider()

    // ponytail: in-memory NSCache only; upgrade to persistent disk cache if bundle icon lookups ever cause main thread hitching.
    private let cache = NSCache<NSString, NSImage>()
    private var missingBundleIds = Set<String>()

    public init() {}

    public func icon(for bundleId: String?) -> NSImage? {
        guard let bundleId = bundleId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleId.isEmpty else {
            return nil
        }

        if let cached = cache.object(forKey: bundleId as NSString) {
            return cached
        }

        if missingBundleIds.contains(bundleId) {
            return nil
        }

        // Special case 1: ConCopy itself
        if bundleId == Bundle.main.bundleIdentifier || bundleId.caseInsensitiveCompare("com.bicsurf.concopy") == .orderedSame {
            let icon = ConCopyAppInfo.loadAppIcon()
            icon.size = NSSize(width: 32, height: 32)
            cache.setObject(icon, forKey: bundleId as NSString)
            return icon
        }

        // Special case 2: macOS screenshot utility
        if bundleId == "com.apple.screencapture" || bundleId == "com.apple.screencaptureui" {
            let screenshotURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.screencaptureui")
                ?? URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
            if FileManager.default.fileExists(atPath: screenshotURL.path) {
                let icon = NSWorkspace.shared.icon(forFile: screenshotURL.path)
                icon.size = NSSize(width: 32, height: 32)
                cache.setObject(icon, forKey: bundleId as NSString)
                return icon
            }
        }

        // Standard resolution via NSWorkspace
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            cache.setObject(icon, forKey: bundleId as NSString)
            return icon
        }

        missingBundleIds.insert(bundleId)
        return nil
    }

    public func clearCache() {
        cache.removeAllObjects()
        missingBundleIds.removeAll()
    }
}

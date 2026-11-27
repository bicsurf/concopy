import Foundation

public struct DeviceIdentifierProvider: Sendable {
    public static let deviceIdentifierKey = "ConCopy.Device.identifier"

    public static func currentDeviceId(userDefaults: UserDefaults = .standard) -> String {
        if let existing = userDefaults.string(forKey: deviceIdentifierKey), !existing.isEmpty {
            return existing
        }
        let newId = UUID().uuidString
        userDefaults.set(newId, forKey: deviceIdentifierKey)
        return newId
    }
}

public enum ConCopySettingsKeys {
    public static let excludeSensitiveFromSyncKey = "ConCopy.Settings.excludeSensitiveFromSync"
    public static let sensitiveClipExpirationMinutesKey = "ConCopy.Settings.sensitiveClipExpirationMinutes"
}

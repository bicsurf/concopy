import Foundation
import os

public enum ConCopyLogger {
    private static let subsystem = "com.local.ConCopy"

    public static let storage = Logger(subsystem: subsystem, category: "Storage")
    public static let sync = Logger(subsystem: subsystem, category: "Sync")
    public static let paste = Logger(subsystem: subsystem, category: "Paste")
    public static let lifecycle = Logger(subsystem: subsystem, category: "Lifecycle")
}

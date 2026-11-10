import Foundation

public struct ClipboardItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let content: String
    public let sourceAppBundleID: String?
    public let timestamp: Date
    public let capturedClip: CapturedClip?

    public init(
        id: UUID = UUID(),
        content: String,
        sourceAppBundleID: String? = nil,
        timestamp: Date = Date(),
        capturedClip: CapturedClip? = nil
    ) {
        self.id = id
        self.content = content
        self.sourceAppBundleID = sourceAppBundleID
        self.timestamp = timestamp
        self.capturedClip = capturedClip
    }
}

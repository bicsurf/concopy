import Foundation

public struct HistoryRetentionPolicy: Sendable {
    public let enabled: Bool
    public let days: Int
    public let maxCount: Int
    public init(enabled: Bool, days: Int, maxCount: Int) {
        self.enabled = enabled
        self.days = days
        self.maxCount = maxCount
    }
    public func apply(to database: DatabaseManager) throws -> Int {
        guard enabled else { return 0 }
        try Task.checkCancellation()
        return try database.pruneClips(olderThanDays: days, maxCount: maxCount)
    }
}

extension DatabaseManager {
    public func fileURLs(for clipID: UUID) throws -> [URL] {
        var representations: [String: Data] = [:]
        for payload in try fetchPayloads(for: clipID)
        where ["public.file-url", FileURLRepresentation.multipleURLsUTI].contains(payload.utiType) {
            representations[payload.utiType] = try loadPayloadData(for: payload)
        }
        return FileURLRepresentation.urls(in: representations)
    }
}

import Foundation

public enum PasteQueueOrder: String, CaseIterable, Identifiable, Sendable {
    case fifo // First in, first out (Queue)
    case lifo // Last in, first out (Stack)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .fifo: return "Queue (FIFO)"
        case .lifo: return "Stack (LIFO)"
        }
    }
}

public struct PasteQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let clip: ClipRecord
    public let addedAt: Date

    public init(clip: ClipRecord, addedAt: Date = Date()) {
        self.id = UUID()
        self.clip = clip
        self.addedAt = addedAt
    }
}

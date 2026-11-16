import Foundation

public enum ClipSortMode: String, Codable, CaseIterable, Sendable {
    case updatedAtDesc
    case createdAtDesc
    case pasteCountDesc
    case manualOrder

    public var displayName: String {
        switch self {
        case .updatedAtDesc: return "Recently Used"
        case .createdAtDesc: return "Creation Date"
        case .pasteCountDesc: return "Most Used"
        case .manualOrder: return "Manual Order"
        }
    }
}

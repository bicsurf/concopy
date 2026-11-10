import Foundation

public enum ClipSortMode: String, Codable, CaseIterable, Sendable {
    case updatedAtDesc
    case createdAtDesc
    case pasteCountDesc
    case manualOrder

    public var displayName: String {
        switch self {
        case .updatedAtDesc: return "Ultimi Usati"
        case .createdAtDesc: return "Data Creazione"
        case .pasteCountDesc: return "Più Utilizzati"
        case .manualOrder: return "Ordine Manuale"
        }
    }
}

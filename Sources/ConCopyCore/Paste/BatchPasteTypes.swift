import Foundation

public enum BatchPasteSeparator: String, Codable, CaseIterable, Sendable {
    case newline = "\n"
    case doubleNewline = "\n\n"
    case tab = "\t"
    case space = " "
    case empty = ""

    public var displayName: String {
        switch self {
        case .newline: return "A capo (\\n)"
        case .doubleNewline: return "Doppio a capo (\\n\\n)"
        case .tab: return "Tabulazione (\\t)"
        case .space: return "Spazio"
        case .empty: return "Nessun separatore"
        }
    }
}

public enum BatchPasteMode: Sendable, Equatable {
    case concatenated(separator: BatchPasteSeparator)
    case sequentialFormFields(delayMs: UInt64)
}

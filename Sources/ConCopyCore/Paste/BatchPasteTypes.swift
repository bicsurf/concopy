import Foundation

public enum BatchPasteSeparator: String, Codable, CaseIterable, Sendable {
    case newline = "\n"
    case doubleNewline = "\n\n"
    case tab = "\t"
    case space = " "
    case empty = ""

    public var displayName: String {
        switch self {
        case .newline: return "New line (\\n)"
        case .doubleNewline: return "Double new line (\\n\\n)"
        case .tab: return "Tab (\\t)"
        case .space: return "Space"
        case .empty: return "No separator"
        }
    }
}

public enum BatchPasteMode: Sendable, Equatable {
    case concatenated(separator: BatchPasteSeparator)
    case sequentialFormFields(delayMs: UInt64)
}

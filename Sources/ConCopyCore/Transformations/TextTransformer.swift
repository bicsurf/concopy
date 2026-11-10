import Foundation

public enum TextTransformation: String, Codable, CaseIterable, Sendable {
    case none
    case uppercase
    case lowercase
    case capitalize
    case trimWhitespace
    case stripBlankLines
    case singleLine

    public var displayName: String {
        switch self {
        case .none: return "Nessuna"
        case .uppercase: return "MAIUSCOLO"
        case .lowercase: return "minuscolo"
        case .capitalize: return "Iniziali Maiuscole"
        case .trimWhitespace: return "Rimuovi Spazi Eccessivi"
        case .stripBlankLines: return "Rimuovi Righe Vuote"
        case .singleLine: return "Tutto su Singola Riga"
        }
    }
}

public struct TextTransformer: Sendable {
    public static func apply(_ transformation: TextTransformation, to input: String) -> String {
        switch transformation {
        case .none:
            return input

        case .uppercase:
            return input.uppercased()

        case .lowercase:
            return input.lowercased()

        case .capitalize:
            return input.capitalized

        case .trimWhitespace:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            let lines = trimmed.components(separatedBy: .newlines)
            let collapsedLines = lines.map { line -> String in
                line.split(separator: " ").joined(separator: " ")
            }
            return collapsedLines.joined(separator: "\n")

        case .stripBlankLines:
            let lines = input.components(separatedBy: .newlines)
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return nonEmpty.joined(separator: "\n")

        case .singleLine:
            let components = input.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return components.joined(separator: " ")
        }
    }
}

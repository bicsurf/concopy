import Foundation

public enum TextTransformation: String, Codable, CaseIterable, Sendable {
    case none
    case uppercase
    case lowercase
    case capitalize
    case trimWhitespace
    case stripBlankLines
    case singleLine
    case jsonFormat
    case jsonMinify
    case urlEncode
    case urlDecode
    case base64Encode
    case base64Decode
    case snakeCase
    case camelCase
    case kebabCase

    public var displayName: String {
        switch self {
        case .none: return "None"
        case .uppercase: return "UPPERCASE"
        case .lowercase: return "lowercase"
        case .capitalize: return "Capitalize"
        case .trimWhitespace: return "Trim Whitespace"
        case .stripBlankLines: return "Remove Blank Lines"
        case .singleLine: return "Single Line"
        case .jsonFormat: return "Format JSON"
        case .jsonMinify: return "Minify JSON"
        case .urlEncode: return "URL Encode"
        case .urlDecode: return "URL Decode"
        case .base64Encode: return "Base64 Encode"
        case .base64Decode: return "Base64 Decode"
        case .snakeCase: return "snake_case"
        case .camelCase: return "camelCase"
        case .kebabCase: return "kebab-case"
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

        case .jsonFormat:
            guard let data = input.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let formattedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                  let formatted = String(data: formattedData, encoding: .utf8) else {
                return input
            }
            return formatted

        case .jsonMinify:
            guard let data = input.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let minifiedData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
                  let minified = String(data: minifiedData, encoding: .utf8) else {
                return input
            }
            return minified

        case .urlEncode:
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input

        case .urlDecode:
            return input.removingPercentEncoding ?? input

        case .base64Encode:
            return Data(input.utf8).base64EncodedString()

        case .base64Decode:
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = Data(base64Encoded: trimmed),
                  let decoded = String(data: data, encoding: .utf8) else {
                return input
            }
            return decoded

        case .snakeCase:
            let w = words(from: input)
            guard !w.isEmpty else { return input }
            return w.map { $0.lowercased() }.joined(separator: "_")

        case .camelCase:
            let w = words(from: input)
            guard !w.isEmpty else { return input }
            let first = w[0].lowercased()
            let rest = w.dropFirst().map { $0.capitalized }
            return ([first] + rest).joined()

        case .kebabCase:
            let w = words(from: input)
            guard !w.isEmpty else { return input }
            return w.map { $0.lowercased() }.joined(separator: "-")
        }
    }

    private static func words(from input: String) -> [String] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let delimiterPattern = "[\\s_\\-\\./\\\\]+"
        guard let regex = try? NSRegularExpression(pattern: delimiterPattern) else {
            return [trimmed]
        }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        let tokenized = regex.stringByReplacingMatches(in: trimmed, range: range, withTemplate: " ")

        var processed = tokenized
        if let camelRegex1 = try? NSRegularExpression(pattern: "([a-z0-9])([A-Z])") {
            let r = NSRange(location: 0, length: (processed as NSString).length)
            processed = camelRegex1.stringByReplacingMatches(in: processed, range: r, withTemplate: "$1 $2")
        }
        if let camelRegex2 = try? NSRegularExpression(pattern: "([A-Z]+)([A-Z][a-z])") {
            let r = NSRange(location: 0, length: (processed as NSString).length)
            processed = camelRegex2.stringByReplacingMatches(in: processed, range: r, withTemplate: "$1 $2")
        }

        return processed.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}

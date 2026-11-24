import Foundation

public struct SnippetVariableResolver: Sendable {
    public static func extractCustomVariables(from template: String) -> [String] {
        var variables: [String] = []
        let pattern = #"\{([a-zA-Z0-9_\-]+)\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }
        let nsString = template as NSString
        let matches = regex.matches(in: template, options: [], range: NSRange(location: 0, length: nsString.length))

        for match in matches {
            if match.numberOfRanges > 1 {
                let varName = nsString.substring(with: match.range(at: 1))
                let lower = varName.lowercased()
                // Built-in variables are not custom inputs
                if lower == "date" || lower == "time" || lower == "datetime" || lower == "clipboard" || lower == "uuid" {
                    continue
                }
                if !variables.contains(varName) {
                    variables.append(varName)
                }
            }
        }
        return variables
    }

    public static func resolve(
        template: String,
        clipboardContent: String? = nil,
        customVariables: [String: String] = [:]
    ) -> String {
        var result = template
        let now = Date()

        // 1. Built-in variables
        // {date}
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dateString = dateFormatter.string(from: now)
        result = result.replacingOccurrences(of: "{date}", with: dateString)

        // {time}
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: now)
        result = result.replacingOccurrences(of: "{time}", with: timeString)

        // {datetime}
        let dateTimeFormatter = DateFormatter()
        dateTimeFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let dateTimeString = dateTimeFormatter.string(from: now)
        result = result.replacingOccurrences(of: "{datetime}", with: dateTimeString)

        // {uuid}
        while result.contains("{uuid}") {
            let uniqueId = UUID().uuidString.lowercased()
            if let range = result.range(of: "{uuid}") {
                result.replaceSubrange(range, with: uniqueId)
            }
        }

        // {clipboard}
        let clip = clipboardContent ?? ""
        result = result.replacingOccurrences(of: "{clipboard}", with: clip)

        // 2. Custom user variables: {variableName}
        for (key, val) in customVariables {
            result = result.replacingOccurrences(of: "{\(key)}", with: val)
        }

        return result
    }
}

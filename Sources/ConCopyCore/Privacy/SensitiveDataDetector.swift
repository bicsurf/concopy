import Foundation

public enum SensitiveDataDetector: Sendable {
    // Regular expressions for detecting sensitive tokens and credentials
    private static let apiKeyPattern = #"(?i)\b(?:sk-[a-zA-Z0-9_\-]{20,}|gh[pousr]_[a-zA-Z0-9]{20,}|bearer\s+[a-zA-Z0-9\-._~+/]+=*|xox[baprs]-[0-9a-zA-Z]{10,}|glpat-[a-zA-Z0-9\-=_]{20,}|aws[a-zA-Z0-9_]{16,})\b"#
    private static let creditCardPattern = #"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13}|3(?:0[0-5]|[68][0-9])[0-9]{11}|6(?:011|5[0-9]{2})[0-9]{12}|(?:2131|1800|35\d{3})\d{11})\b"#
    private static let genericSecretPattern = #"(?i)\b(?:password|secret|apikey|api_key|token|access_token|private_key)\s*[:=]\s*([^\s]{8,})"#

    public static func isSensitive(_ text: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        if text.range(of: apiKeyPattern, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: creditCardPattern, options: .regularExpression) != nil {
            return true
        }
        if text.range(of: genericSecretPattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    public static func maskSensitiveText(_ text: String) -> String {
        guard isSensitive(text) else { return text }

        var result = text

        // 1. Mask credit cards: preserve first 4 and last 4
        if let cardRegex = try? NSRegularExpression(pattern: creditCardPattern, options: []) {
            let nsStr = result as NSString
            let matches = cardRegex.matches(in: result, options: [], range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let card = nsStr.substring(with: match.range)
                if card.count >= 8 {
                    let prefix = String(card.prefix(4))
                    let suffix = String(card.suffix(4))
                    let masked = "\(prefix) •••• •••• \(suffix)"
                    result = (result as NSString).replacingCharacters(in: match.range, with: masked)
                }
            }
        }

        // 2. Mask API Keys / Tokens: preserve prefix (first 7 chars) then ••••••••
        if let tokenRegex = try? NSRegularExpression(pattern: apiKeyPattern, options: []) {
            let nsStr = result as NSString
            let matches = tokenRegex.matches(in: result, options: [], range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                let token = nsStr.substring(with: match.range)
                let prefixLen = min(7, token.count / 3)
                let prefix = String(token.prefix(prefixLen))
                let masked = "\(prefix)••••••••••••"
                result = (result as NSString).replacingCharacters(in: match.range, with: masked)
            }
        }

        // 3. Mask key-value secrets
        if let secretRegex = try? NSRegularExpression(pattern: genericSecretPattern, options: []) {
            let nsStr = result as NSString
            let matches = secretRegex.matches(in: result, options: [], range: NSRange(location: 0, length: nsStr.length))
            for match in matches.reversed() {
                if match.numberOfRanges > 1 {
                    let secretRange = match.range(at: 1)
                    let masked = "••••••••"
                    result = (result as NSString).replacingCharacters(in: secretRange, with: masked)
                }
            }
        }

        return result
    }
}
